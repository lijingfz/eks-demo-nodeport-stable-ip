#!/usr/bin/env bash
# Allocate 3 EIPs (one per AZ) and tag them for later NLB binding.
#
# state.txt format (POSTMORTEM M1):
#   Kept as a plain list (one allocation-id per line) plus a CSV line, written
#   via printf so leading whitespace can never sneak in. Downstream scripts
#   parse it with extract_eip_allocs() in scripts/common.sh — never `source`.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../00-prerequisites/env.sh"

STATE="$SCRIPT_DIR/state.txt"
if [[ -f "$STATE" ]] && grep -q "^eipalloc-" "$STATE"; then
  log "state.txt already has EIP allocations:"
  grep "^eipalloc-" "$STATE"
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

# Plain, grep-friendly format. Never `source` this file.
{
  printf '%s\n' "${ALLOCS[@]}"
  printf 'CSV=%s\n' "$(IFS=,; echo "${ALLOCS[*]}")"
} > "$STATE"
ok "wrote $STATE"
