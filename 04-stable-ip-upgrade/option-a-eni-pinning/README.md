# 方案 A — Secondary ENI Pinning（节点 secondary 网卡 IP 不变）

> **不推荐作为第一选择**。此方案复杂、限制多；大多数"IP 不变"的业务诉求用方案 B 已经解决。
> 仅当客户上游系统**逐节点**做 IP 白名单、且无法接受接入 NLB 中转时使用。

## 原理

1. 在目标子网里**预先创建** N 个 ENI（N = 节点数），打 tag `slot=1..N`、`Owner=eks-stable-ip`。
2. **不使用托管节点组**，改用自管节点组（eksctl `nodeGroups:` 或 CloudFormation ASG）。
3. 节点 LaunchTemplate 的 UserData 在 boot 时：
   - 读 EC2 instance tag `slot`；
   - `describe-network-interfaces` 按 tag 找到对应 ENI；
   - `attach-network-interface --device-index 1`；
   - 把次网卡加入路由表，让 Pod 出栈流量走次网卡。
4. 升级节点：
   - cordon + drain 旧节点；
   - `detach-network-interface` 摘走 secondary ENI；
   - terminate 旧 EC2，ASG 拉起新 EC2；
   - 新 EC2 UserData 重新 attach 同一个 ENI → IP 不变。

## 关键限制

- **只保 secondary IP 稳定**，主 ENI 的 primary IP 仍随新 EC2 重新分配。业务只要走 secondary 即可。
- ENI 和 EC2 必须在**同一 AZ**，slot 到 AZ 的映射要固定，不能随便在 AZ 间漂。
- 不支持自动扩缩容到 N+1 节点（需要预分配第 N+1 个 ENI）。
- `VPC CNI` 默认会把 secondary ENI 也拿去分 Pod IP，会打架。必须：
  - 给节点打 taint `node.k8s.aws/no-cni-enable=true`，或
  - 通过 `WARM_ENI_TARGET=0`、`MAX_ENI=1` 限制 CNI 只用 primary ENI。

## 交付物（本目录）

- `launch-template-userdata.sh`：节点启动时 attach secondary ENI 的脚本骨架（需要填入 slot→ENI 映射逻辑）。
- `pre-create-enis.sh`：批量预创建 ENI 并打 tag。
- `upgrade-one-node.sh`：单节点升级脚本（detach → terminate → 等新实例 → 验证 attach）。

> 真正要在客户环境落地时：先与客户确认 slot 管理（通常用 DynamoDB 或 SSM Parameter Store 做 slot→ENI→InstanceId 三方映射），并写幂等的回收逻辑。本 demo 只给骨架。
