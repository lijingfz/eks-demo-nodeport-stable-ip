#!/usr/bin/env bash
# Create the demo cluster from cluster.yaml. Will prompt before any AWS call.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../00-prerequisites/env.sh"

log "About to create EKS cluster:"
log "  name=$CLUSTER_NAME  version=$CLUSTER_VERSION  region=$AWS_REGION"
log "  config=$SCRIPT_DIR/cluster.yaml"
log "  estimated time: 15-20 min"
warn "This creates a VPC, IGW, NAT GW (hourly cost), 2x t3.large, EKS control plane (\$0.10/h)."

confirm "Proceed with cluster creation?"

eksctl create cluster -f "$SCRIPT_DIR/cluster.yaml"

ok "cluster created — updating kubeconfig"
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"

log "Nodes:"
kubectl get nodes -o wide

log "Addons:"
aws eks list-addons --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" --output table

ok "cluster ready. Next:"
echo "  cd ../02-nodepool-console-ready && ./apply-fix.sh"
echo "  cd ../03-nodeport-demo && ./verify.sh"
