# 议题 4 — AWS 控制台创建节点组失败的成因与修复

> **2026-05-06 实测记录**：在 eksctl 0.219 + EKS 1.35 上，根因 #2（子网缺 `kubernetes.io/cluster/<name>=shared` 标签）**默认必定命中**——eksctl 新版本的 CFN 模板不再打这个 tag。
> 因此 `apply-fix.sh` 里的打 tag 步骤是**必需**的，不是"防御性"代码。详见 [`POSTMORTEM.md`](../POSTMORTEM.md#p2) P2。

## 常见根因（按命中率排序）

| # | 根因 | 识别方法 | 修复位置 |
|---|------|---------|----------|
| 1 | **Node IAM Role 不是信任 `ec2.amazonaws.com`**，或缺 `AmazonEKSWorkerNodePolicy` / `AmazonEC2ContainerRegistryReadOnly` / `AmazonEKS_CNI_Policy` 中任一策略。控制台 Node IAM role 下拉会直接过滤掉不合规的 Role，看起来"没得选"或选了之后 CFN 在 `CREATE_FAILED` 时报 `InvalidParameterException: nodeRole is invalid` | `aws iam get-role --role-name <role>`；`aws iam list-attached-role-policies` | `iam-noderole.yaml` 重建 Role |
| 2 | **子网缺少 `kubernetes.io/cluster/<cluster-name>=shared\|owned` 标签**。控制台会检查子网标签，没打会报 `subnets are not tagged correctly` | `aws ec2 describe-subnets --subnet-ids ...` | `apply-fix.sh` 自动补标签 |
| 3 | **子网同一 AZ 出现冲突**：EKS 控制平面已在 AZ-a 占了一个 ENI，但你选的节点子网在 AZ-a 没有可用 IP 或被标成私网但无 NAT 出口。控制台创建时 EC2 launch 失败，CFN 日志：`Instances failed to join the kubernetes cluster` | CloudFormation 事件 + `aws ec2 describe-subnets` 的 `AvailableIpAddressCount` | 换大子网或删 pod-subnet 冲突 |
| 4 | **自定义 Launch Template 字段冲突**：控制台里同时指定了 AMI ID 又指定了 `amiType`，或 LT 里写了 UserData 但没有调用 `bootstrap.sh`。托管节点组约束很严，任一冲突都 400 | CFN 报 `You cannot specify an AMI ID and an AMI type...` | 用 `amiType=AL2023_x86_64_STANDARD`，让 EKS 自己装 |
| 5 | **SCP / Permission boundary 阻断**：企业账号常见，`iam:PassRole` 被 boundary 拒绝，但 CLI / yaml 通过 IRSA 绕过 | CloudTrail `AccessDenied` | 补 boundary 或走 CLI |
| 6 | **VPC CNI / kube-proxy / CoreDNS 插件版本不兼容 1.35**：老插件在新控制面上 `Degraded`，新节点 NotReady，控制台 5 分钟后回滚。1.33 起 AWS 对 addon 版本检查更严格 | `aws eks describe-addon-versions --kubernetes-version 1.35` | `cluster.yaml` 中已声明 addon，eksctl 会挑 1.35 兼容版 |
| 7 | **AMI type 与实例架构不匹配**：比如选了 `t4g.medium`（arm64）但 AMI type 是 `AL2023_x86_64_STANDARD` | CFN 事件 | 选 `AL2023_ARM_64_STANDARD` |
| 8 | **节点组名字重名或带了非法字符**（`_`、空格）| 控制台 client-side 报错 | 改名 |
| 9 | **端点私有+无 bastion**：控制面纯私有端点，节点 kubelet 在 AZ 没路由到 EKS ENI | kubelet 日志 | 打开 publicAccess 或修 route |

## 本 demo 的修复做了什么

1. 使用 `eksctl` 创建集群时，已：
   - 给 VPC 所有子网打 `kubernetes.io/cluster/eks-demo=shared` 以及 `kubernetes.io/role/internal-elb=1`（私网）、`kubernetes.io/role/elb=1`（公网）。
   - OIDC 已 enable，IRSA 可用。
2. 本目录补一个**通用 Node IAM Role**（`eksDemoNodeRole`），控制台创建节点组时直接在下拉里就能看到它。
3. `apply-fix.sh` 幂等地：
   - 创建/修复 `eksDemoNodeRole`（附 3 个托管策略 + EBS CSI + SSM）；
   - 回填子网标签（如果 eksctl 已经打过则跳过）；
   - 打印控制台创建节点组时应选择的参数（AMI type、instance type、subnets、node role）。

## 控制台创建节点组推荐参数（修复后）

```
Name:                eks-demo-ng-console
Node IAM role:       eksDemoNodeRole
AMI type:            Amazon Linux 2023 (AL2023_x86_64_STANDARD)
Instance types:      t3.large
Disk size:           50 GiB (gp3)
Desired size:        2    Min: 2    Max: 4
Subnets:             选 3 个 private subnets（tag: kubernetes.io/role/internal-elb=1）
Launch template:     不要选，留空（让 EKS 用默认）
Remote access:       关闭（生产推荐用 SSM Session Manager）
Labels/Taints:       可选
Update config:       Max unavailable = 1（默认即可）
```

## 验证

创建完成后：

```bash
aws eks list-nodegroups --cluster-name eks-demo --region us-east-1
kubectl get nodes -l eks.amazonaws.com/nodegroup=eks-demo-ng-console
```
