#!/usr/bin/env bash
# Allocate 3 EIPs (one per AZ) and tag them for later NLB binding.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../00-prerequisites/env.sh"

STATE="$SCRIPT_DIR/state.txt"
if [[ -f "$STATE" ]] && grep -q "^EIP_ALLOCS=" "$STATE"; then
  log "state.txt already has EIP allocations:"
  grep ^EIP "$STATE"
  exit 0
fi

warn "Will allocate 3 Elastic IPs in $AWS_REGION. Each costs a little when unattached."
confirm "Allocate 3 EIPs?"

ALLOCS=()
for az in "$AZ_A" "$AZ_B" "$AZ_C"; do
  ALLOC_ID=$(aws ec2 allocate-address --region "$AWS_REGION" --domain vpc \
    --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Owner,Value=$CLUSTER_TAG_OWNER},{Key=Purpose,Value=eks-stable-nlb},{Key=AZ,Value=$az}]" \
    --query 'AllocationId' --output text)
  PUBLIC_IP=$(aws ec2 describe-addresses --region "$AWS_REGION" \
    --allocation-ids "$ALLOC_ID" --query 'Addresses[0].PublicIp' --output text)
  ok "AZ $az -> $ALLOC_ID ($PUBLIC_IP)"
  ALLOCS+=("$ALLOC_ID")
done

{
  echo "EIP_ALLOCS=${ALLOCS[*]}"
  echo "EIP_ALLOCS_CSV=$(IFS=,; echo "${ALLOCS[*]}")"
} > "$STATE"
ok "wrote $STATE"
