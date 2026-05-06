#!/usr/bin/env bash
# End-to-end verification of NodePort (A) and NLB->NodePort (C).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../00-prerequisites/env.sh"

log "Applying app and services..."
confirm "Apply app.yaml and nlb-to-nodeport.yaml?"
kubectl apply -f "$SCRIPT_DIR/app.yaml"

# EKS 1.33+ removed in-tree cloud-provider-aws service controller; type=LoadBalancer
# requires aws-load-balancer-controller to be reconciled. Install if missing.
# Chart version pinned to avoid silent upstream changes (POSTMORTEM N2).
LBC_CHART_VERSION="${LBC_CHART_VERSION:-3.3.0}"
if ! kubectl -n kube-system get deploy aws-load-balancer-controller >/dev/null 2>&1; then
  warn "aws-load-balancer-controller not installed. On EKS 1.33+ it is required to reconcile type=LoadBalancer Services."
  confirm "Install aws-load-balancer-controller via Helm (chart $LBC_CHART_VERSION) now?"
  helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
  helm repo update eks
  helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
    --version "$LBC_CHART_VERSION" \
    -n kube-system \
    --set clusterName="$CLUSTER_NAME" \
    --set serviceAccount.create=false \
    --set serviceAccount.name=aws-load-balancer-controller
  kubectl -n kube-system rollout status deploy/aws-load-balancer-controller --timeout=180s
fi

kubectl apply -f "$SCRIPT_DIR/nlb-to-nodeport.yaml"

log "Waiting for deployment to be ready..."
kubectl -n "$DEMO_NS" rollout status deploy/demo --timeout=180s

log "Services:"
kubectl -n "$DEMO_NS" get svc -o wide

# --- A: NodePort, from inside VPC ---
log "Verifying A (NodePort) from a debug pod inside the cluster..."
NODE_IP=$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
kubectl run curl-$$ --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -s --max-time 5 "http://$NODE_IP:$DEMO_NODEPORT" || warn "NodePort reachability from pod failed"

# --- C: NLB ---
log "Waiting up to 5 min for NLB hostname..."
for i in {1..60}; do
  ELB=$(kubectl -n "$DEMO_NS" get svc demo-nlb -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [[ -n "${ELB:-}" ]] && break
  sleep 5
done
[[ -z "${ELB:-}" ]] && { err "NLB hostname not ready after 5 min"; exit 1; }
ok "NLB hostname: $ELB"

log "Curling NLB (may take 1-2 min for targets to become healthy)..."
for i in {1..30}; do
  if curl -s --max-time 3 "http://$ELB" | grep -q "hello from"; then
    ok "NLB reachable and returning pod response"
    curl -s "http://$ELB"; echo
    exit 0
  fi
  sleep 10
done
err "NLB did not return expected response within 5 min"
exit 1
