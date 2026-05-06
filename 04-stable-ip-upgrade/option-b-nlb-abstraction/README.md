# 方案 B — NLB + 静态 EIP 抽象掉节点 IP（推荐）

目标：**不保证节点主 IP 不变，但保证对外访问的 VIP（3 个 EIP + 1 个 DNS）永远不变**。

节点组正常滚升，新节点被自动注册到 NLB TargetGroup，旧节点 deregister；外部客户端无感。

## 步骤

1. `01-allocate-eips.sh` — 分配 3 个 EIP（每 AZ 一个）并打 tag。
2. `02-deploy-service-with-eips.sh` — 部署 demo app，Service 类型 LoadBalancer，用 annotation 把 EIP 绑给 NLB。
3. `03-record-ips.sh` — 把当前节点 Internal IP 和 NLB EIP 记录到 `state.txt`。
4. `04-upgrade-nodegroup.sh` — 用 `aws eks update-nodegroup-version` 触发节点组升级（AMI 新版本）。
5. `05-verify-ips.sh` — 升级完成后对比：节点 IP 已变，EIP 未变，服务未中断（持续 curl）。

## 前置

- `aws-load-balancer-controller` 已安装（本 demo 里 01-cluster 尚未默认装，`02-deploy-service-with-eips.sh` 会提示是否安装，或使用 in-tree cloud-provider 的 NLB——但 in-tree 不支持指定 EIP，所以 EIP 绑定**必须**用 aws-load-balancer-controller）。

## 公网 NLB vs 内网 NLB

本目录下的 01→05 脚本默认是 **公网 NLB + 3 个静态 EIP**（`scheme: internet-facing`）。如果客户的访问来源**在 AWS 内网**（同 VPC / Peering / TGW / DX / VPN 对端），应改用**内网 NLB**，省 EIP 费、更安全，且议题 3 的"IP 不变"通过 `private-ipv4-addresses` annotation 同样成立。

详细差异、manifest 示例、DNS 解析注意事项见 [`INTERNAL-NLB.md`](INTERNAL-NLB.md)。
