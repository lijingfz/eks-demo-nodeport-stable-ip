# EKS Demo 项目

面向客户演示的 EKS 集群搭建与四项议题验证脚本集合。本项目**默认不自动执行任何创建动作**，所有资源创建脚本在运行时会打印将要执行的动作并等待交互确认。

## 环境

- Region: `us-east-1`（可通过 `AWS_REGION` 环境变量覆盖）
- Account: 从 `aws sts get-caller-identity` 自动解析（不再硬编码）
- 工具：`aws-cli 2.31+`、`eksctl 0.219+`、`kubectl`、`helm`

## 目录结构

```
.
├── 00-prerequisites/               # IAM / 预检 / 变量
│   ├── env.sh                      # 统一环境变量（所有脚本 source 此文件）
│   └── preflight.sh                # 权限、配额、AZ、IP 段预检
├── 01-cluster/                     # EKS 集群与托管节点组
│   ├── cluster.yaml                # eksctl ClusterConfig（唯一声明源）
│   ├── create-cluster.sh           # 创建集群（交互式确认）
│   └── destroy-cluster.sh          # 销毁集群（交互式确认）
├── 02-nodepool-console-ready/      # 议题 4：解决控制台创建节点组失败
│   ├── README.md                   # 原因分析与修复方案
│   ├── iam-noderole.yaml           # 可被控制台识别的 Node IAM Role
│   └── apply-fix.sh                # 应用修复（IAM、Tag、子网标签）
├── 03-nodeport-demo/               # 议题 2：NodePort 暴露（不使用 Ingress）
│   ├── README.md                   # NodePort vs LoadBalancer vs Ingress 说明
│   ├── app.yaml                    # Demo 应用 + NodePort Service
│   ├── nlb-to-nodeport.yaml        # 可选：前置 NLB 指向 NodePort（非 Ingress）
│   ├── sg-open-nodeport.sh         # 打开节点安全组 NodePort 端口
│   └── verify.sh                   # 端到端验证脚本
├── 04-stable-ip-upgrade/           # 议题 3：节点升级 IP 不变
│   ├── README.md                   # 三套方案对比
│   ├── option-a-eni-pinning/       # A：ENI 固定 + 自管节点
│   ├── option-b-nlb-abstraction/   # B：用 NLB/Target Group 抽象掉节点 IP（推荐）
│   └── option-c-self-managed/      # C：自管节点 ASG + 恢复脚本
├── scripts/
│   ├── common.sh                   # 通用函数（confirm、log、require）
│   └── tear-down-all.sh            # 一键销毁：Services → NS → EIPs → IAM stack → 集群
└── POSTMORTEM.md                   # 2026-05-06 首次部署复盘，5 个踩过的坑都已回填到脚本
```

## 评审清单（建议按顺序 review）

| # | 文件 | 关注点 |
|---|------|--------|
| 1 | `00-prerequisites/env.sh` | 集群名、版本、CIDR、节点规格是否符合演示预期 |
| 2 | `01-cluster/cluster.yaml` | VPC/子网/节点组/IRSA/插件版本 |
| 3 | `01-cluster/create-cluster.sh` | 创建流程与回滚路径 |
| 4 | `02-nodepool-console-ready/README.md` | 控制台创建失败根因分析 |
| 5 | `03-nodeport-demo/` | NodePort 方案与安全组开放策略 |
| 6 | `04-stable-ip-upgrade/README.md` | IP 稳定方案选型与限制 |

review 通过后依次执行：

```bash
cd 00-prerequisites && ./preflight.sh
cd ../01-cluster && ./create-cluster.sh
cd ../02-nodepool-console-ready && ./apply-fix.sh
cd ../03-nodeport-demo && ./verify.sh
# 议题 3 升级验证：
cd ../04-stable-ip-upgrade/option-b-nlb-abstraction
./01-allocate-eips.sh && ./02-deploy-service-with-eips.sh
./03-record-ips.sh && ./04-upgrade-nodegroup.sh && ./05-verify-ips.sh
```

## 清理

```bash
./scripts/tear-down-all.sh
```

## 复盘

首次部署中遇到的 5 个真实坑（EBS CSI ARN 路径、子网 tag 缺失、tab 分隔、升级秒回、describe-update 参数名）及其修复已全部回填到脚本中，细节见 [`POSTMORTEM.md`](POSTMORTEM.md)。未来一键部署无需再手工介入。
