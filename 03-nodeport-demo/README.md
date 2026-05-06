# 议题 2 — 不使用 Ingress，直接用 Service NodePort 暴露

## 客户原话

> "用 svc 的 nodeport 暴露？ 我们有没有不用 ingress 的，就是 nodeport 的那种 loadbalance？"

翻译一下需求是两件事同时要：

1. **不引入 Ingress Controller**（不装 ALB/Nginx/Traefik 任何一个）。
2. 仍希望**前面有一层 LB** 把流量分到多个节点，而不是直接把某一个节点 IP 暴露给用户。

## 三种组合对比

| 方案 | 对应 K8s 资源 | 是否 Ingress | 是否 LB | 可看到的"LB" | 适用场景 |
|------|---------------|--------------|---------|--------------|----------|
| A. **纯 NodePort** | `type: NodePort` | 否 | 否 | 无（客户端自己访问任一节点 IP :NodePort） | 内网、自己已有 LB、开发调试 |
| B. **NodePort + 外部 NLB/ALB (非 K8s 管理)** | `type: NodePort` + 手工建 NLB TargetGroup 指向节点 | 否 | 是（AWS NLB） | 有 | 有已存在的 NLB、想让 K8s "不碰" LB |
| C. `type: LoadBalancer` (NLB instance 模式) | `type: LoadBalancer` + `aws-load-balancer-type=nlb` `nlb-target-type=instance` | 否（是 LB 不是 Ingress） | 是（NLB） | 有 | 客户要"LB 但不要 Ingress"最省事 |

客户那句"nodeport 的那种 loadbalance"描述的**就是 B 或 C**——区别只是 LB 由谁创建。

## 本 demo 同时交付 A + C，并留 B 的步骤说明

- **A（基础）** `app.yaml`：2 副本 nginx + `Service type=NodePort port=31080`。
- **C（推荐给客户）** `nlb-to-nodeport.yaml`：同一后端再定义一个 `Service type=LoadBalancer`，通过 `service.beta.kubernetes.io/aws-load-balancer-type: external` + `nlb-target-type: instance`，由 **aws-load-balancer-controller**（Deployment 形态，非 Ingress）自动建 NLB，**NLB 的 Target 是节点 + NodePort**——没有任何 Ingress Controller。
  - ⚠️ 1.35 说明：EKS 1.33+ 已移除 in-tree `cloud-provider-aws` 的 service 控制器，**`type: LoadBalancer` 必须有 aws-load-balancer-controller**（LBC）才会被真正 reconcile。`verify.sh` 会检测并在缺失时通过 Helm 安装。这仍然不是 Ingress，只是一个 Deployment 形态的控制器，和 Ingress Controller 的使用方式完全不同。
- **B（说明）** 见本文档末尾"手工 NLB"章节。

## ⚠️ 方案 A 的外网访问前提

纯 NodePort（方案 A）要**从公网**能访问，节点必须：

1. 部署在**公网子网**（本 demo 的 `cluster.yaml` 默认 `privateNetworking: true`，所以节点在私网，A 方案只能从 VPC 内测试）；
2. 在节点 SG 上放通 NodePort 端口（`sg-open-nodeport.sh`）。

如果你要给客户演示 "外网 → NodePort" 真链路：
- 方案 A 暂时把节点组改到公网子网（把 `cluster.yaml` 里 `privateNetworking` 改成 `false`），或
- 走堡垒机 / VPN / Session Manager 从 VPC 内访问，或
- 直接用**方案 C**（NLB → NodePort），NLB 自己在公网、节点留在私网——**这也是推荐做法**。

## NodePort 安全组

托管节点组的 EC2 安全组默认只放通 `443`、`1025-65535` 内部通信。NodePort (`31080`) 要让外网访问必须显式放通。`sg-open-nodeport.sh` 会：

1. 查询节点组关联的 SG；
2. 交互式询问来源 CIDR（默认仅打开你当前公网 IP/32）；
3. `authorize-security-group-ingress` 放通 TCP 31080。

**⚠️ 演示用。生产不要把 NodePort 直接暴露到 0.0.0.0/0**——即便是 C 方案，NLB 回源到节点也是走内网 SG，不需要公网放通 31080。

## 验证

```bash
# 1. 部署
kubectl apply -f app.yaml
kubectl apply -f nlb-to-nodeport.yaml    # C 方案

# 2. 看到 NodePort 端口
kubectl -n nodeport-demo get svc

# 3. A 方案（任一节点公网 IP，如果节点有公网 IP）
#    或从 VPC 内堡垒机：
NODE_IP=$(kubectl get node -o wide -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
curl http://$NODE_IP:31080

# 4. C 方案（NLB DNS，几分钟后生效）
ELB=$(kubectl -n nodeport-demo get svc demo-nlb -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl http://$ELB
```

`verify.sh` 会把上面 4 步自动跑一遍并打印每一步结果。

## 手工 NLB（方案 B）步骤

如果客户环境里 LB 归网络组管、K8s 不允许自己创建：

```bash
# 1. 建 target group（type=instance，端口=NodePort）
aws elbv2 create-target-group \
  --name eks-demo-nodeport \
  --protocol TCP --port 31080 \
  --vpc-id <vpc-id> \
  --target-type instance \
  --health-check-protocol HTTP --health-check-port 31080 --health-check-path /

# 2. 注册节点实例
aws elbv2 register-targets --target-group-arn <tg-arn> \
  --targets Id=<i-xxx> Id=<i-yyy>

# 3. 建 NLB
aws elbv2 create-load-balancer --name eks-demo-nlb --type network \
  --subnets <public-subnet-ids>

# 4. 建 listener TCP 80 -> target group
aws elbv2 create-listener --load-balancer-arn <nlb-arn> \
  --protocol TCP --port 80 \
  --default-actions Type=forward,TargetGroupArn=<tg-arn>
```

节点扩缩容时需要自己同步 register/deregister（不推荐，除非有强约束）。
