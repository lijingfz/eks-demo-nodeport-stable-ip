# 议题 3 — 节点升级过程中内网 IP 保持不变

## 结论先行

**EKS 托管节点组（Managed Nodegroup）升级本质上是"创建新 EC2、Drain 旧节点、终止旧 EC2"。新 EC2 会从子网 CIDR 中重新分配 IP，因此托管节点组本身无法保证节点主 IP 不变。**

真正能做到"升级后 IP 不变"的只有三种技术手段，下面列出可行性与代价，demo 用方案 B 作为推荐落地，ABC 都在对应目录里有可跑脚本。

## 方案对比

| 方案 | IP 粒度 | 节点形态 | 升级方式 | 是否能在 EKS 托管节点组做 | 客户场景评估 |
|------|---------|---------|----------|---------------------------|---------------|
| **A. ENI 固定（secondary ENI pinning）** | 每节点有一个"固定 secondary ENI"，IP 稳定；主 ENI 仍会变 | 自管 EC2（或托管 + Launch Template 脚本）| 滚升时把 secondary ENI 从旧实例 detach → attach 到新实例 | **无法**原生支持托管节点组；需要自管或 lifecycle hook 定制 | 有白名单基于节点 IP 的上游系统 |
| **B. NLB / Target Group 抽象节点 IP（推荐）** | 不保节点 IP，但**用户看到的 VIP / DNS 永远不变**；且 NLB 支持分配**静态 EIP** | 托管节点组即可 | 正常滚升，NLB 自动将新节点注册进 TargetGroup | ✅ 完全原生支持 | 绝大多数客户的真实诉求是"访问入口不变"，这个方案够了 |
| **C. 自管节点 ASG + 动态恢复 IP** | 节点主 IP 可稳定（用固定 ENI + Launch Template UserData 在启动时重新 attach） | 自管 EC2 | 自己写 cordon / drain / swap 脚本 | N/A，本就是自管 | 强 IP 绑定（Java License、数据库防火墙…） |

## 如何选

1. 客户只要"访问入口不变"、"不要上游系统频繁改白名单"——选 **B**，零侵入、成本低。
2. 客户上游是"按节点 IP 粒度做白名单"、且不接受接入 LB 做中转——选 **A**。
3. 客户还想要 SSH 到节点的 IP 都别变，或要迁入已有 IP 段不能重分配——选 **C**。

## 各方案实现细节

### A. ENI pinning

- 预分配一组 ENI（数量 = 节点数），打上 tag `Owner=eks-stable-ip`。
- 节点 Launch Template 的 UserData 在 EC2 启动时：
  - 根据实例 tag `slot=N` 找到对应 ENI；
  - `aws ec2 attach-network-interface` 把该 ENI attach 为 `device-index=1`；
  - 配置路由让工作负载流量从 eth1 出。
- 升级流程：
  1. `aws ec2 detach-network-interface` 从旧实例摘掉；
  2. 终止旧实例；
  3. 新实例 boot 时 UserData 再 attach 回来。

**限制**：
- 只适合固定副本数（non-auto-scale），slot 管理复杂；
- ENI 仍属于同一 AZ，新实例若换 AZ 会失败；
- 不能用在托管节点组（EKS 不让你改 UserData 的底层逻辑，且 MNG 的 LT 只允许有限字段）。

详见 `option-a-eni-pinning/`。

### B. NLB 抽象（推荐）

- 在集群前放一个 **NLB + 静态 EIP**（每 AZ 一个 EIP，永远不变）。
- 服务用 `type: LoadBalancer` + `service.beta.kubernetes.io/aws-load-balancer-eip-allocations`，把 EIP 分配给 NLB。
- 节点升级时：NLB TargetGroup 自动 deregister 旧节点、register 新节点；**客户端看到的 DNS 和 EIP 都不变**。
- 如果 client 是"按 IP 白名单"的，只需让对端放通这组 EIP（3 个 /32），一次配置终身不变。

详见 `option-b-nlb-abstraction/`。

### C. 自管节点 ASG + 固定 ENI

- 不用托管节点组，用 eksctl 的 `nodeGroups:`（注意：不是 managedNodeGroups）或 CloudFormation 自建 ASG。
- ASG 的 LaunchTemplate 里：
  - `NetworkInterfaces` 声明 `DeviceIndex=0`、`NetworkInterfaceId=<预先创建的 ENI>`（但 ASG 要 N 个实例就要 N 个预建 ENI，需要 N 个 ASG or MixedInstancesPolicy 搞不定，通常用 1 ASG = 1 实例 的组合）。
- 升级：
  1. cordon + drain 旧实例；
  2. `aws autoscaling terminate-instance-in-auto-scaling-group`，ASG 重新拉起；
  3. UserData 把原 ENI 重新 attach（或 LaunchTemplate 直接指定 ENI，新实例就带上来）。

详见 `option-c-self-managed/`。

## 本 demo 在方案 B 上的完整验证流程

```bash
cd option-b-nlb-abstraction
./01-allocate-eips.sh              # 分配 3 个 EIP（每 AZ 一个）
./02-deploy-service-with-eips.sh   # 部署 demo app + NLB Service 绑定 EIP
./03-record-ips.sh                 # 记录节点 IP 和 EIP
./04-upgrade-nodegroup.sh          # 触发节点组升级（版本或 AMI）
./05-verify-ips.sh                 # 确认：节点 IP 变了 / EIP 没变 / 服务未中断
```
