# 方案 C — 自管节点 ASG + 固定 ENI（节点主 IP 稳定）

> 适用于"连 primary IP 都不能变"的极端场景（License 绑 IP、数据库审计、安全设备按节点 IP 做关联）。

## 核心思路

- 抛弃托管节点组（Managed Nodegroup）的抽象，直接用 **EC2 AutoScaling Group + LaunchTemplate**。
- LaunchTemplate 的 `NetworkInterfaces[0]` 直接指定一个**预先创建好的 ENI**（primary ENI）。
- 升级（换 AMI / Kubernetes 版本）：
  1. 先创建新版本 LaunchTemplate 指向同一个 ENI；
  2. `terminate-instance-in-auto-scaling-group --should-decrement-desired-capacity=false` 强制替换；
  3. 新实例起来时带着同一个 ENI → primary IP 不变。
- 为满足"多个节点"，一个 ASG 只放 **1 个实例**（min=max=1），有 N 个节点就建 N 个 ASG，每个绑各自的 ENI。

## 关键限制 / 注意

- **ENI 与实例必须同 AZ**。跨 AZ 漂不可能。
- ASG 一实例组的架构意味着失去 ASG 的弹性伸缩能力；如果业务要弹，用方案 B。
- 节点必须是**自管**形态：需要自己维护 AMI 升级、kubelet 参数、CNI 等。EKS Optimized AMI 可以通过 SSM Parameter 拿到。
- VPC CNI 要做调整：默认会把辅助 ENI 都拿去分 pod IP，可能和外部管理的 secondary ENI 冲突（如果你同时用方案 A）。

## 交付物

- `eksctl-nodegroups-self.yaml`：eksctl 自管节点组配置骨架（`nodeGroups:` 段）。
- `create-asg-with-fixed-eni.sh`：不走 eksctl，直接用 AWS CLI 创建 LaunchTemplate + 1-instance ASG，ENI 由 `--network-interfaces` 固定。
- `upgrade-in-place.sh`：触发 instance refresh，IP 不变的验证脚本。

## 执行顺序

```bash
./create-asg-with-fixed-eni.sh        # 建 ENI + LT + ASG (min=max=1)
# 等节点 Ready:  kubectl get nodes
./upgrade-in-place.sh <asg-name>      # 验证升级 → IP 不变
```
