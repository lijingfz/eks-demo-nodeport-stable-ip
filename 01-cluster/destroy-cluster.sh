#!/usr/bin/env bash
# Destroy the cluster and all resources created by cluster.yaml.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../00-prerequisites/env.sh"

warn "This will DELETE the cluster $CLUSTER_NAME and its VPC/subnets/nodegroups."
warn "Any LoadBalancer Services or EBS volumes NOT cleaned up first may orphan resources."

log "Checking for Services of type LoadBalancer..."
kubectl get svc -A --field-selector spec.type=LoadBalancer 2>/dev/null || true
log "Checking for PVCs..."
kubectl get pvc -A 2>/dev/null || true

confirm "Proceed with full cluster teardown?"

eksctl delete cluster -f "$SCRIPT_DIR/cluster.yaml" --disable-nodegroup-eviction

ok "delete command issued — check CloudFormation stacks for residuals:"
echo "  aws cloudformation list-stacks --region $AWS_REGION --query 'StackSummaries[?contains(StackName, \`$CLUSTER_NAME\`)].StackName'"
