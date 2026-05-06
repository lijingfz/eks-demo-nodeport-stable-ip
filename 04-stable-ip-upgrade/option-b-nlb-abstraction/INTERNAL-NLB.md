# 方案 B 变种 — 内网 NLB（`scheme: internal`）

## 什么时候用内网 NLB

| 访问来源 | 选公网 NLB | 选内网 NLB |
|----------|-----------|------------|
| 公网客户、合作方 IP 白名单 | ✅ | |
| 同 VPC 其他服务 | | ✅ |
| VPC Peering / Transit Gateway / Direct Connect / VPN 对端 | | ✅ |
| 前面还有 ALB / CloudFront / API Gateway 做 L7 | | ✅（让 L7 走内网访问后端） |

**省的钱**：内网 NLB 无需 EIP（省 3×$3.6/月），也不产生公网出口流量费。

## 与公网 NLB 的差异（只有 annotation 三行不同）

| annotation | 公网（本 demo 默认） | 内网 |
|------------|----------------------|------|
| `aws-load-balancer-scheme` | `internet-facing` | **`internal`** |
| `aws-load-balancer-subnets` | 3 个公网子网（tag `kubernetes.io/role/elb=1`） | **3 个私网子网**（tag `kubernetes.io/role/internal-elb=1`） |
| `aws-load-balancer-eip-allocations` | 3 个 EIP allocation ID | **不写**（内网 NLB 不能绑 EIP） |
| `aws-load-balancer-private-ipv4-addresses`（可选） | — | **指定 3 个私网 IP**，跨 NLB 重建保持不变 |

其余（`aws-load-balancer-type: external`、`nlb-target-type: instance`、`cross-zone-load-balancing-enabled: true`）都一样。

## 议题 3 的"IP 不变"在内网模式怎么保

公网模式下，IP 由 EIP 固定 → NLB 重建也不变。

内网模式下有两种做法：

1. **不显式指定**私网 IP：默认每次 NLB 创建，3 个 ENI 从子网 CIDR 池里随机分配私网 IP。**NLB 不被重建**（比如只是节点升级）时 IP 不变；但如果有人 `kubectl delete svc` 再重建 Service，IP 可能换。对"节点升级 IP 不变"这件事**已经足够**。
2. **显式指定**私网 IP：加上 `aws-load-balancer-private-ipv4-addresses` annotation（注意每个子网内该 IP 必须是空闲且不在 subnet reserved range 的），**即使 Service 重建 NLB 也用同一组私网 IP**。对"按 IP 白名单"的上游更稳。

选 IP 时要避开 AWS 每个子网保留的前 4 个 + 最后 1 个：子网 `10.80.0.0/19` 保留 `10.80.0.0`、`10.80.0.1`、`10.80.0.2`、`10.80.0.3`、`10.80.31.255`，其他可用。

## 完整 manifest 示例（把 `02-deploy-service-with-eips.sh` 改成内网版）

在项目里新建 `nlb-service-internal.yaml`（或改那个渲染脚本），annotation 段换成：

```yaml
apiVersion: v1
kind: Service
metadata:
  name: demo-nlb-stable
  namespace: stable-ip-demo
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: external
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: instance
    # ---- 差异开始 ----
    service.beta.kubernetes.io/aws-load-balancer-scheme: internal
    service.beta.kubernetes.io/aws-load-balancer-subnets: "subnet-private-a,subnet-private-b,subnet-private-c"
    # （可选）显式固定私网 IP，确保 Service 重建后仍然不变：
    service.beta.kubernetes.io/aws-load-balancer-private-ipv4-addresses: "10.80.99.10,10.80.131.10,10.80.163.10"
    # ---- 差异结束 ----
    service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled: "true"
spec:
  type: LoadBalancer
  selector: { app: demo }
  ports:
    - { name: http, port: 80, targetPort: 80, protocol: TCP }
```

## 执行差异（相对公网流程）

```bash
# 跳过 01-allocate-eips.sh —— 内网 NLB 不需要 EIP

# 02 直接部署内网 NLB Service（把 annotation 改为 internal 版）
kubectl apply -f nlb-service-internal.yaml

# 03 record-ips / 04 upgrade / 05 verify 与公网版完全一样，
#    区别是 "EIPs" 一栏换成 "NLB ENI PrivateIp"。
```

`03-record-ips.sh` / `05-verify-ips.sh` 原本读的是 EIP；对应查内网 NLB 私网 IP 的命令：

```bash
NLB_NAME=$(kubectl -n stable-ip-demo get svc demo-nlb-stable \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' | cut -d- -f1-4)

aws elbv2 describe-load-balancers --region "$AWS_REGION" \
  --query "LoadBalancers[?starts_with(DNSName, \`$NLB_NAME\`)].AvailabilityZones[].[ZoneName,LoadBalancerAddresses[0].PrivateIPv4Address]" \
  --output table
```

## 从客户环境怎么访问这个内网 NLB

内网 NLB 的 DNS 名（例如 `internal-k8s-stableip-xxx.elb.us-east-1.amazonaws.com`）只能从以下位置解析/访问：

- **同 VPC 内**：任何 EC2 / EKS Pod / Lambda（配置在该 VPC 的）直接 curl；
- **Peered VPC**：建好 VPC Peering + 双向路由 + 修改 DNS 解析设置（`enableDnsSupport=true`、两侧都要）后可直接用 DNS；
- **Transit Gateway 连接的 VPC**：类似 Peering；
- **Direct Connect / Site-to-Site VPN**：对端内网可通，但 **DNS 解析需要 Route 53 Inbound Resolver** 才能把 NLB DNS 解析给 on-prem；直接用私网 IP 也可以，这就是上面 `private-ipv4-addresses` 的用处；
- **公网**：访问不到（这是设计目标）。

## 不能用内网 NLB 的情况

1. **客户端在公网** → 必须公网 NLB；
2. **需要 Global Accelerator** → GA 只能挂公网 NLB；
3. **TLS 证书来自 ACM Public CA** → 通常搭公网 NLB；内网场景常用 ACM Private CA 或业务层自管证书。
