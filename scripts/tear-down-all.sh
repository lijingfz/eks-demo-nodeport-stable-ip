#!/usr/bin/env bash
# One-shot teardown in dependency order. Each step is idempotent and guarded
# by a confirm prompt.  Run from any directory.
#
# Order matters (POSTMORTEM "teardown" section):
#   1) delete Services of type LoadBalancer — let LBC reconcile and delete NLBs
#      (skipping this step leaves orphan NLBs + target groups after cluster
#       teardown because the cluster is gone before LBC can clean up)
#   2) delete namespaces created by demos (frees PVCs if any)
#   3) release EIPs (only possible after NLB deleted above; describe-addresses
#      will show AssociationId=None when safe to release)
#   4) delete the IAM Role CFN stack
#   5) `eksctl delete cluster -f cluster.yaml` — removes VPC/NAT/IGW/nodegroup
#   6) sanity check for leftover CFN stacks
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO_DIR/00-prerequisites/env.sh"

warn "This script WILL DESTROY the entire eks-demo stack:"
warn "  - LoadBalancer Services (2 NLBs)"
warn "  - Namespaces nodeport-demo, stable-ip-demo"
warn "  - 3 EIPs from stable-ip demo"
warn "  - CloudFormation stack eks-demo-node-iam-role"
warn "  - EKS cluster $CLUSTER_NAME and its entire VPC"
confirm "Proceed with full teardown?"

# ---- 1. LoadBalancer Services first (let LBC clean up NLBs) ----
log "1/6  delete LoadBalancer Services (NLBs)"
kubectl -n nodeport-demo  delete svc demo-nlb        --ignore-not-found
kubectl -n stable-ip-demo delete svc demo-nlb-stable --ignore-not-found
log "wait 30s for LBC to finish NLB deletion..."
sleep 30

# ---- 2. namespaces ----
log "2/6  delete demo namespaces"
kubectl delete ns nodeport-demo   --ignore-not-found --timeout=120s || true
kubectl delete ns stable-ip-demo  --ignore-not-found --timeout=120s || true

# ---- 3. EIPs ----
#
# POSTMORTEM M1: Do NOT `source` state.txt — a malformed value (e.g. leading
# whitespace from a hand-written inline command) causes bash to execute the
# allocation ID as a command under `set -e` and abort the whole teardown.
# Parse the file with extract_eip_allocs(), and always follow with a
# tag-based sweep so a missing/corrupt state.txt never leaks EIPs.
log "3/6  release EIPs created by stable-ip demo"
STATE_FILE="$REPO_DIR/04-stable-ip-upgrade/option-b-nlb-abstraction/state.txt"

release_eip_if_free() {
  local a="$1"
  local assoc
  assoc=$(aws ec2 describe-addresses --region "$AWS_REGION" \
    --allocation-ids "$a" \
    --query 'Addresses[0].AssociationId' --output text 2>/dev/null || echo "None")
  if [[ "$assoc" != "None" && -n "$assoc" ]]; then
    warn "EIP $a still associated ($assoc); skipping. Delete the NLB first."
    return 0
  fi
  aws ec2 release-address --region "$AWS_REGION" --allocation-id "$a" \
    && ok "released $a" \
    || warn "could not release $a (already gone?)"
}

# 3a. from state.txt (safe parse; bash 3.2 compat — no mapfile)
read_lines STATE_IDS "$(extract_eip_allocs "$STATE_FILE")"
if [[ ${#STATE_IDS[@]} -gt 0 ]]; then
  log "from state.txt: ${STATE_IDS[*]}"
  for a in "${STATE_IDS[@]}"; do release_eip_if_free "$a"; done
else
  log "state.txt missing or empty — relying on tag sweep below"
fi

# 3b. tag-based sweep — catches orphans from failed earlier runs
TAG_SWEEP_OUT=$(aws ec2 describe-addresses --region "$AWS_REGION" \
  --filters "Name=tag:Purpose,Values=eks-stable-nlb" \
  --query 'Addresses[?AssociationId==null].AllocationId' --output text | tr '\t' '\n')
read_lines TAG_IDS "$TAG_SWEEP_OUT"
if [[ ${#TAG_IDS[@]} -gt 0 ]]; then
  log "tag sweep (Purpose=eks-stable-nlb, unassociated): ${TAG_IDS[*]}"
  for a in "${TAG_IDS[@]}"; do release_eip_if_free "$a"; done
fi

rm -f "$STATE_FILE"

# ---- 4. IAM Role stack ----
log "4/6  delete IAM Role stack"
aws cloudformation delete-stack --region "$AWS_REGION" --stack-name eks-demo-node-iam-role || true
aws cloudformation wait stack-delete-complete --region "$AWS_REGION" \
  --stack-name eks-demo-node-iam-role 2>/dev/null || true

# ---- 5. cluster ----
#
# POSTMORTEM P7: `eksctl delete cluster` exits as soon as it issues all
# sub-stack delete calls, while the root `eksctl-<name>-cluster` stack
# (VPC/NAT/EKS) is still DELETE_IN_PROGRESS. If you stop here the cluster
# and VPC linger for another ~5 min, and any follow-up command that checks
# for "clean account" will report false positives. Wait explicitly.
log "5/6  delete EKS cluster (this is the long step, ~10 min)"
eksctl delete cluster -f "$REPO_DIR/01-cluster/cluster.yaml" --disable-nodegroup-eviction

log "     waiting for root cluster stack to fully delete..."
aws cloudformation wait stack-delete-complete --region "$AWS_REGION" \
  --stack-name "eksctl-$CLUSTER_NAME-cluster" 2>/dev/null || true
# `wait stack-delete-complete` returns success BOTH when the stack reaches
# DELETE_COMPLETE and when it no longer exists — exactly what we want.
ok "     cluster stack gone"

# ---- 6. leftover check ----
log "6/6  check for leftover resources"
echo "  CFN stacks:"
aws cloudformation list-stacks --region "$AWS_REGION" \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE DELETE_FAILED \
  --query "StackSummaries[?contains(StackName, \`$CLUSTER_NAME\`)].[StackName,StackStatus]" \
  --output table
echo "  EKS clusters in region:"
aws eks list-clusters --region "$AWS_REGION" --output text || true
echo "  VPCs with demo CIDR $VPC_CIDR:"
aws ec2 describe-vpcs --region "$AWS_REGION" \
  --filters "Name=cidr,Values=$VPC_CIDR" --query 'Vpcs[].VpcId' --output text || true
echo "  EIPs tagged Purpose=eks-stable-nlb:"
aws ec2 describe-addresses --region "$AWS_REGION" \
  --filters "Name=tag:Purpose,Values=eks-stable-nlb" \
  --query 'Addresses[].AllocationId' --output text || true

ok "teardown complete"
