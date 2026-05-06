#!/usr/bin/env bash
# Ensure aws-load-balancer-controller is installed, then deploy an NLB service
# bound to the 3 EIPs from step 01.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../00-prerequisites/env.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/state.txt"

# 1. aws-load-balancer-controller (required for NLB + static EIP binding).
# LBC_CHART_VERSION is pinned so a future upstream bump doesn't silently change
# behavior. Bump deliberately after re-testing — see POSTMORTEM N2.
LBC_CHART_VERSION="${LBC_CHART_VERSION:-3.3.0}"
if ! kubectl -n kube-system get deploy aws-load-balancer-controller >/dev/null 2>&1; then
  warn "aws-load-balancer-controller not found."
  confirm "Install it via Helm (chart $LBC_CHART_VERSION) now?"
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

# 2. Get public subnets for scheme=internet-facing
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)
PUBLIC_SUBNETS=$(aws ec2 describe-subnets --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:kubernetes.io/role/elb,Values=1" \
  --query 'Subnets[].SubnetId' --output text | tr '\t' ',')

log "EIP allocations: $EIP_ALLOCS_CSV"
log "Public subnets:  $PUBLIC_SUBNETS"

# 3. Render manifest
cat > "$SCRIPT_DIR/nlb-service.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata: { name: stable-ip-demo }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: demo, namespace: stable-ip-demo }
spec:
  replicas: 3
  selector: { matchLabels: { app: demo } }
  template:
    metadata: { labels: { app: demo } }
    spec:
      containers:
        - name: web
          image: public.ecr.aws/nginx/nginx:1.27-alpine
          ports: [{ containerPort: 80 }]
          lifecycle:
            postStart:
              exec:
                command: ["/bin/sh","-c","echo \"from \$HOSTNAME\" > /usr/share/nginx/html/index.html"]
---
apiVersion: v1
kind: Service
metadata:
  name: demo-nlb-stable
  namespace: stable-ip-demo
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: external
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: instance
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
    service.beta.kubernetes.io/aws-load-balancer-subnets: ${PUBLIC_SUBNETS}
    service.beta.kubernetes.io/aws-load-balancer-eip-allocations: ${EIP_ALLOCS_CSV}
    service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled: "true"
spec:
  type: LoadBalancer
  selector: { app: demo }
  ports:
    - { name: http, port: 80, targetPort: 80, protocol: TCP }
EOF

confirm "Apply nlb-service.yaml?"
kubectl apply -f "$SCRIPT_DIR/nlb-service.yaml"
kubectl -n stable-ip-demo rollout status deploy/demo --timeout=180s
ok "deployed. Wait ~3 min for NLB provisioning, then run 03-record-ips.sh"
