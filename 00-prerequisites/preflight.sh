#!/usr/bin/env bash
# Read-only preflight: identity / quotas / AZs / existing clusters.
set -euo pipefail
source "$(dirname "$0")/env.sh"

require aws eksctl kubectl helm jq

log "AWS identity:"
aws sts get-caller-identity --output table

log "Region=$AWS_REGION  Cluster=$CLUSTER_NAME  Version=$CLUSTER_VERSION"

log "Availability zones:"
aws ec2 describe-availability-zones --region "$AWS_REGION" \
  --query 'AvailabilityZones[].ZoneName' --output text

log "Existing EKS clusters in region:"
aws eks list-clusters --region "$AWS_REGION" --output table || true

log "VPCs using CIDR $VPC_CIDR (should be empty before create):"
aws ec2 describe-vpcs --region "$AWS_REGION" \
  --filters "Name=cidr,Values=$VPC_CIDR" \
  --query 'Vpcs[].VpcId' --output text || true

log "EIP quota (check before stable-IP demo):"
aws service-quotas get-service-quota \
  --service-code ec2 --quota-code L-0263D0A3 --output table 2>/dev/null || \
  warn "EIP quota lookup skipped (no service-quotas permission)"

ok "preflight done — no resources were modified"
