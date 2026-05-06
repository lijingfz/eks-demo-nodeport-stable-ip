#!/usr/bin/env bash
# Single source of truth for all scripts. Source this file before any action.

# ---- identity / region ----
export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"
# Resolved lazily from caller identity — do NOT hardcode, keeps the repo portable.
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo UNKNOWN)}"
export AWS_ACCOUNT_ID

# ---- cluster ----
export CLUSTER_NAME="eks-demo"
export CLUSTER_VERSION="1.35"        # EKS 当前默认版本（标准支持期内，截至 2026-05）
export CLUSTER_TAG_OWNER="eks-demo"
export CLUSTER_TAG_PURPOSE="demo"

# ---- networking ----
# 全新 VPC；若要接入现有 VPC，把下面 CIDR 改成目标段，并在 cluster.yaml 中改用 subnets 段
export VPC_CIDR="10.80.0.0/16"
export AZ_A="us-east-1a"
export AZ_B="us-east-1b"
export AZ_C="us-east-1c"

# ---- nodegroup ----
export NG_NAME="ng-demo"
export NG_INSTANCE_TYPE="t3.large"
export NG_DESIRED=2
export NG_MIN=2
export NG_MAX=4
export NG_DISK_GIB=50

# ---- demo app ----
export DEMO_NS="nodeport-demo"
export DEMO_NODEPORT=31080            # 范围 30000-32767

# ---- stable-ip demo ----
export STABLE_NG_NAME="ng-stable-ip"
export STABLE_NG_SIZE=2

SCRIPT_DIR_COMMON="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR_COMMON/scripts/common.sh"
