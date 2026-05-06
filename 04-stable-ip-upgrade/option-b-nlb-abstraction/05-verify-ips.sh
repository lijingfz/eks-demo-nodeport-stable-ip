#!/usr/bin/env bash
# After nodegroup upgrade: confirm node IPs changed, EIPs unchanged, service healthy.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../00-prerequisites/env.sh"

BEFORE="$SCRIPT_DIR/snapshot-before.txt"
AFTER="$SCRIPT_DIR/snapshot-after.txt"
[[ -f "$BEFORE" ]] || { err "missing $BEFORE; run 03-record-ips.sh before upgrade"; exit 1; }

{
  echo "# captured $(date -u +%FT%TZ)"
  echo "## Node IPs"
  kubectl get nodes -o custom-columns=NAME:.metadata.name,INTERNAL:.status.addresses[?\(@.type==\"InternalIP\"\)].address --no-headers
  echo
  echo "## NLB"
  kubectl -n stable-ip-demo get svc demo-nlb-stable -o wide
  echo
  echo "## EIPs"
  # POSTMORTEM M1: safe parse, never source state.txt (bash 3.2 compat)
  read_lines EIP_IDS "$(extract_eip_allocs "$SCRIPT_DIR/state.txt")"
  for a in "${EIP_IDS[@]:-}"; do
    [[ -z "$a" ]] && continue
    aws ec2 describe-addresses --region "$AWS_REGION" --allocation-ids "$a" \
      --query 'Addresses[0].[AllocationId,PublicIp,AssociationId]' --output text
  done
} > "$AFTER"

log "===== BEFORE ====="; cat "$BEFORE"
log "===== AFTER  ====="; cat "$AFTER"

log ""
log "Diff summary:"
diff -u "$BEFORE" "$AFTER" || true

ELB=$(kubectl -n stable-ip-demo get svc demo-nlb-stable -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
log ""
log "Service check:"
curl -sI --max-time 5 "http://$ELB" | head -1 || warn "curl failed"

ok "Expected outcome: node InternalIP values differ; EIP PublicIp values identical; HTTP 200 throughout."
