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
log "3/6  release EIPs created by stable-ip demo"
STATE_FILE="$REPO_DIR/04-stable-ip-upgrade/option-b-nlb-abstraction/state.txt"
if [[ -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  for a in $EIP_ALLOCS; do
    ASSOC=$(aws ec2 describe-addresses --region "$AWS_REGION" \
      --allocation-ids "$a" \
      --query 'Addresses[0].AssociationId' --output text 2>/dev/null || echo "None")
    if [[ "$ASSOC" != "None" && -n "$ASSOC" ]]; then
      warn "EIP $a still associated ($ASSOC); skipping. Delete the NLB first."
      continue
    fi
    aws ec2 release-address --region "$AWS_REGION" --allocation-id "$a" \
      && ok "released $a" \
      || warn "could not release $a (already gone?)"
  done
  rm -f "$STATE_FILE"
else
  log "no state.txt; skipping EIP release"
fi

# Fallback: release any EIP tagged Purpose=eks-stable-nlb that's unassociated
for a in $(aws ec2 describe-addresses --region "$AWS_REGION" \
             --filters "Name=tag:Purpose,Values=eks-stable-nlb" \
             --query 'Addresses[?AssociationId==null].AllocationId' --output text | tr '\t' '\n'); do
  aws ec2 release-address --region "$AWS_REGION" --allocation-id "$a" \
    && ok "released orphan $a" || true
done

# ---- 4. IAM Role stack ----
log "4/6  delete IAM Role stack"
aws cloudformation delete-stack --region "$AWS_REGION" --stack-name eks-demo-node-iam-role || true
aws cloudformation wait stack-delete-complete --region "$AWS_REGION" \
  --stack-name eks-demo-node-iam-role 2>/dev/null || true

# ---- 5. cluster ----
log "5/6  delete EKS cluster (this is the long step, ~10 min)"
eksctl delete cluster -f "$REPO_DIR/01-cluster/cluster.yaml" --disable-nodegroup-eviction

# ---- 6. leftover check ----
log "6/6  check for leftover CFN stacks"
aws cloudformation list-stacks --region "$AWS_REGION" \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE DELETE_FAILED \
  --query "StackSummaries[?contains(StackName, \`$CLUSTER_NAME\`)].[StackName,StackStatus]" \
  --output table

ok "teardown complete"
