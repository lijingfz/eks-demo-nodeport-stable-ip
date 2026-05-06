#!/usr/bin/env bash
# Snapshot node internal IPs + NLB EIPs before upgrade.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../00-prerequisites/env.sh"

SNAP="$SCRIPT_DIR/snapshot-before.txt"

{
  echo "# captured $(date -u +%FT%TZ)"
  echo "## Node IPs"
  kubectl get nodes -o custom-columns=NAME:.metadata.name,INTERNAL:.status.addresses[?\(@.type==\"InternalIP\"\)].address --no-headers
  echo
  echo "## NLB"
  kubectl -n stable-ip-demo get svc demo-nlb-stable -o wide
  echo
  echo "## EIPs"
  source "$SCRIPT_DIR/state.txt"
  for a in $EIP_ALLOCS; do
    aws ec2 describe-addresses --region "$AWS_REGION" --allocation-ids "$a" \
      --query 'Addresses[0].[AllocationId,PublicIp,AssociationId,NetworkInterfaceOwnerId]' --output text
  done
} | tee "$SNAP"

ok "snapshot saved to $SNAP"
