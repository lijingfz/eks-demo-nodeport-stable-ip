# 安装过程复盘

记录一次从零到完成四项议题验证期间遇到的所有问题、误报与非预期行为。时间：2026-05-06，集群 `eks-demo` v1.35.4，eksctl 0.219.0。

## 真实问题（Blocking，必须解决才能继续）

### P1. `AmazonEBSCSIDriverPolicy` ARN 路径错误，CFN 创建 Node IAM Role 失败

- **症状**：`aws cloudformation deploy -f iam-noderole.yaml` 失败，事件：
  ```
  Policy arn:aws:iam::aws:policy/AmazonEBSCSIDriverPolicy does not exist or is not attachable.
  ```
- **根因**：AWS 把这个策略挂在了 `service-role/` 路径下，正确 ARN 是
  `arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy`。我凭印象写成了顶层路径。
- **处理**：`iam-noderole.yaml` 第 20 行改为 `service-role/AmazonEBSCSIDriverPolicy`，删除旧 stack 重建。
- **教训**：AWS 托管策略 ARN 不是全都在 `iam::aws:policy/` 下，有 `service-role/`、`aws-service-role/` 等子路径。写死前先 `aws iam list-policies --scope AWS --query 'Policies[?PolicyName==\`X\`].Arn'` 查一下。

### P2. eksctl 0.219 + EKS 1.35 不再自动打 `kubernetes.io/cluster/<name>` 子网标签

- **症状**：eksctl 创建完 VPC 后，6 个子网只有 `kubernetes.io/role/elb=1` 和 `kubernetes.io/role/internal-elb=1`，**缺** `kubernetes.io/cluster/eks-demo=shared`。这正是议题 4 第 2 类根因。
- **影响**：不补这个 tag 的话，AWS 控制台创建节点组会报 "subnets are not tagged correctly"；in-tree cloud-provider 找子网也会失败。
- **处理**：`apply-fix.sh` 里的补标签逻辑（原本是"防御性"代码）实际被命中。本次通过循环给所有子网打了 `kubernetes.io/cluster/eks-demo=shared`。
- **教训**：不要假设 eksctl 新版本的行为和旧版一致。每次换 eksctl 或 EKS 主版本都要验一遍子网标签。

### P3. Bash 字段分隔：`aws ... --output text` 返回 tab 分隔，不能直接喂给 `--resources`

- **症状**：
  ```bash
  ALL_SUBNETS=$(aws ec2 describe-subnets ... --output text)   # tab-separated
  aws ec2 create-tags --resources "$ALL_SUBNETS"              # fails
  # "The ID 'subnet-0d93...\tsubnet-0a97...\t...' is not valid"
  ```
- **根因**：`create-tags --resources` 接受多个 ID 但必须用**空格**分隔，或用 `$(...)` 不加引号让 word splitting 生效。加了双引号就整段当成一个 ID 了。
- **处理**：改为 `for s in $(... | tr '\t' '\n'); do aws ec2 create-tags --resources "$s"; done`。
- **教训**：shell 里处理 AWS CLI tab 输出要么用 `tr '\t' '\n'` 拆行，要么用 `--output text` 加 `xargs`，别靠 IFS 运气。

### P4. `update-nodegroup-version` 对已是 latest 的节点组 51 秒秒回 ACTIVE，未真正替换节点

- **症状**：触发节点组版本升级后，EKS 立刻返回 `status=ACTIVE`，节点 AGE 还是 20 分钟，说明根本没做滚动替换。
- **根因**：集群和 AMI 都是当天拉的 latest（`1.35.4-20260423`），EKS 判断无事可做。
- **处理**：用 `aws autoscaling terminate-instance-in-auto-scaling-group --no-should-decrement-desired-capacity` 手动终止一个节点，让 ASG 重新拉实例来模拟升级中的替换行为。这也是升级期间实际发生的底层动作。
- **教训**：**demo 脚本里的"升级验证"必须确保真的能触发节点替换**。要么：
  1. 故意创建一个旧 AMI 的节点组再升级；
  2. 或在 demo 脚本里加一步强制 terminate 节点的路径。
  > 建议后续把 `04-upgrade-nodegroup.sh` 扩展成：先 `describe-nodegroup` 看 `version/releaseVersion`，若已是 latest 就提示改用 `terminate-instance-in-auto-scaling-group` 模拟。

### P5. `aws eks describe-update` 的参数名是 `--name`（集群名）不是 `--cluster-name`

- **症状**：
  ```bash
  aws eks describe-update --name <update-id> --cluster-name eks-demo ...
  # the following arguments are required: --update-id
  ```
- **根因**：这个子命令的参数约定反直觉：`--name` 指集群名，`--update-id` 才是 update ID。大多数其他 `aws eks ...` 子命令用 `--cluster-name`。
- **处理**：`aws eks describe-update --update-id <id> --name eks-demo --nodegroup-name ng-demo`。
- **教训**：EKS CLI 每个子命令的集群参数名不完全统一，不确定时 `aws eks <verb> help`。

## 误报与需要主动分辨的噪音

### N1. eksctl 日志里的 "OIDC is disabled" 警告

- **原文**：`recommended policies were found for "vpc-cni" addon, but since OIDC is disabled on the cluster, eksctl cannot configure the requested permissions`
- **实际**：OIDC provider 已建好，`aws-load-balancer-controller` 和 `ebs-csi-controller-sa` 两个 IRSA ServiceAccount 都成功创建。这是 eksctl 在 addon 对应的 pod-identity 路径上的保守输出，不是真正的故障。
- **如何确认**：`kubectl -n kube-system get sa aws-load-balancer-controller -o yaml | grep role-arn` 有 ARN 就说明 IRSA 是通的。

### N2. Helm chart version fallback 到 3.3.0

- **原文**：`unable to find exact version; falling back to closest available version chart=aws-load-balancer-controller requested="" selected=3.3.0`
- **实际**：本次未指定 `--version`，所以 Helm 挑了仓库里最新的 3.3.0 版本。部署成功、运行正常。
- **建议**：生产脚本里固定 `--version`，避免哪天上游 chart 大版本跳变时 demo 突然挂。

### N3. 预检里 `aws eks list-clusters` 空，但 `describe-vpcs` 里有一个 `eksctl-eks-test-cluster/VPC`

- **实际**：这是 2024-07 某次 eks-workshop 留下的**孤儿 CFN stack**——集群本身早删了，VPC / NAT / EIP 还在 `10.42.0.0/16` 空跑产生费用。
- **本次决定**：不动它，demo 用 `10.80.0.0/16`，无冲突。
- **待办**：demo 结束后单独清理这一组 stack（stack 名以 `eksctl-eks-test-` 开头），能省 NAT GW 月费 ~$33。

## 本可以预见、通过脚本避免的小问题

### M1. 手工内联命令生成 EIP CSV 时前导逗号（脚本本身无此问题）

- **症状**（本次复现时的内联命令）：
  ```bash
  ALLOCS="" ; for az in ...; do ... ALLOCS="$ALLOCS $ALLOC_ID"; done
  CSV=$(echo $ALLOCS | tr ' ' ',')
  # 结果 CSV=,eipalloc-xxx,eipalloc-yyy,eipalloc-zzz   ← 前导逗号
  ```
- **根因**：`""` 开头拼接，首次循环产生 `" eipalloc-xxx"`，`tr ' ' ','` 就有前导逗号。
- **脚本实际无此问题**：`01-allocate-eips.sh` 里用的是 `ALLOCS=()` 数组 + `$(IFS=,; echo "${ALLOCS[*]}")`，天然正确。复盘时本人只是**没跑该脚本**，而是在 terminal 里手写了一段等价的内联命令时犯错。
- **教训**：别临时手写等价命令绕过已写好的脚本；要么直接跑脚本，要么按脚本里的数组写法写内联。

### M2. NodePort 对外访问未实际用到

- 虽然 `03-nodeport-demo/sg-open-nodeport.sh` 为方案 A 准备了开 SG 的逻辑，实际验证时因为节点在私网、没有 public IP，直接从 Pod 内 curl 了一下就过。**真要给客户演示 A 方案从外网访问 NodePort，得把节点组改为 `privateNetworking: false` 或者通过堡垒机。**
- **待办**：README 里明确标注 "A 方案真·外网访问需要公网子网节点"。

## 时间线（关键节点）

| UTC 时间 | 事件 |
|----------|------|
| 11:55 | `eksctl create cluster` 启动 |
| 12:07 | 控制面就绪 |
| 12:11 | 节点 Ready，5 个 addon active |
| — | 控制台修复：CFN 失败 → 改 EBS CSI ARN → 成功 |
| — | 子网补 `kubernetes.io/cluster/` tag |
| 12:18 | aws-load-balancer-controller (Helm 3.3.0) |
| — | NodePort demo 通过：A（内网 curl）+ C（NLB 3 分钟 healthy） |
| 04:15 | 分配 3 个 EIP |
| 04:24 | 部署 stable-ip-demo，NLB 绑定 3 EIP |
| 04:26 | 拍 before 快照 |
| 04:28 | 触发"升级"—— EKS 秒回，判定不动节点 |
| 04:30 | 改走 ASG terminate，模拟替换 |
| 04:33 | 新节点（新内网 IP）Ready，旧节点 drain 完退出 |
| 04:34 | after 快照：节点 IP 变了，3 个 EIP 完全不变，83/83 次 curl 200 |

## 建议后续改进（✅ 已全部落地到代码中）

| # | 项 | 状态 | 落地位置 |
|---|----|------|----------|
| 1 | `iam-noderole.yaml` 用正确的 EBS CSI ARN 路径 | ✅ | `02-nodepool-console-ready/iam-noderole.yaml` 已用 `service-role/AmazonEBSCSIDriverPolicy` |
| 2 | 子网补 tag 无条件幂等执行（1.35 默认缺） | ✅ | `02-nodepool-console-ready/apply-fix.sh` Step 2 改为 always-tag |
| 3 | `01-allocate-eips.sh` 用数组拼 CSV | ✅ | 脚本本身早已正确（M1 是手工命令的问题） |
| 4 | `04-upgrade-nodegroup.sh` 检测 latest 自动降级到 ASG terminate | ✅ | 新增 `MODE=version\|terminate` 分支，对比 `releaseVersion` |
| 5 | Helm 固定 chart version | ✅ | `03-nodeport-demo/verify.sh` + `04/02-deploy-service-with-eips.sh` 都 pin 到 `LBC_CHART_VERSION=3.3.0` |
| 6 | README 补 NodePort 外网访问前提 | ✅ | `03-nodeport-demo/README.md` 顶部加 "方案 A 的外网访问前提" 小节 |
| 7 | 统一 tear-down 脚本 | ✅ | `scripts/tear-down-all.sh`，按 Service→NS→EIP→IAM→cluster 顺序销毁 |
| 8 | `02-nodepool-console-ready/README.md` 标注 1.35 必打 tag | ✅ | README 首段提示 + 指向本文件 P2 |

## 一键清理

上面 7 条的第 (7) 项——统一 tear-down——已实现为 `scripts/tear-down-all.sh`，按以下依赖顺序执行并每步幂等：

```
1. kubectl delete svc demo-nlb / demo-nlb-stable      # 让 LBC 清理 NLB
2. kubectl delete ns nodeport-demo / stable-ip-demo   # 清理 Deployment/PVC
3. aws ec2 release-address                             # 释放 3 个 EIP（仅当 Association 已空）
4. aws cloudformation delete-stack eks-demo-node-iam-role
5. eksctl delete cluster -f 01-cluster/cluster.yaml    # VPC/NAT/IGW 全部带走
6. 列出残留 CFN stack 供人工复核
```

使用：

```bash
cd /Users/lijing/Desktop/AI-code/EKS-test
./scripts/tear-down-all.sh
```
