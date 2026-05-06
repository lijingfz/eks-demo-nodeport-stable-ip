#!/usr/bin/env bash
# Trigger a node replacement on the managed nodegroup so we can verify that the
# NLB EIPs stay unchanged.
#
# Why this is more than a simple `update-nodegroup-version` (POSTMORTEM P4):
#   If the nodegroup is already on the latest release (very common the same day
#   the cluster is created), `update-nodegroup-version` returns status=Successful
#   in ~50 seconds WITHOUT replacing any EC2 instance. The IP-stability demo
#   needs an actual replacement, so we detect this case and fall back to
#   `terminate-instance-in-auto-scaling-group`, which is what the upgrade would
#   do internally anyway.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../00-prerequisites/env.sh"

NG=$(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'nodegroups[0]' --output text)
log "Target nodegroup: $NG"

ELB=$(kubectl -n stable-ip-demo get svc demo-nlb-stable \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
log "NLB DNS: $ELB"

# Pick an EIP to curl against during the upgrade (first EIP from state.txt).
# POSTMORTEM M1: safe parse, never source state.txt (bash 3.2 compat)
read_lines EIP_IDS "$(extract_eip_allocs "$SCRIPT_DIR/state.txt")"
[[ ${#EIP_IDS[@]} -ge 1 ]] || { err "no EIP allocations in state.txt"; exit 1; }
FIRST_ALLOC="${EIP_IDS[0]}"
FIRST_EIP=$(aws ec2 describe-addresses --region "$AWS_REGION" \
  --allocation-ids "$FIRST_ALLOC" --query 'Addresses[0].PublicIp' --output text)
log "Will verify zero-downtime against EIP $FIRST_EIP during replacement."

# Is the nodegroup already on the latest release?
CURRENT_RELEASE=$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name "$NG" --region "$AWS_REGION" --query 'nodegroup.releaseVersion' --output text)
AMI_TYPE=$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name "$NG" --region "$AWS_REGION" --query 'nodegroup.amiType' --output text)
K8S_VER=$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name "$NG" --region "$AWS_REGION" --query 'nodegroup.version' --output text)
LATEST_RELEASE=$(aws ssm get-parameter --region "$AWS_REGION" \
  --name "/aws/service/eks/optimized-ami/$K8S_VER/amazon-linux-2023/x86_64/standard/recommended/release_version" \
  --query 'Parameter.Value' --output text 2>/dev/null || echo "unknown")

log "Current releaseVersion: $CURRENT_RELEASE"
log "Latest releaseVersion:  $LATEST_RELEASE"
log "amiType=$AMI_TYPE  k8s=$K8S_VER"

MODE="version"
if [[ "$CURRENT_RELEASE" == "$LATEST_RELEASE" || "$LATEST_RELEASE" == "unknown" ]]; then
  warn "Nodegroup already at latest — update-nodegroup-version would be a no-op."
  warn "Falling back to ASG terminate to force a real replacement."
  MODE="terminate"
fi

warn "Start a background curl loop in another terminal to watch availability:"
echo "  while true; do printf '%s ' \$(date +%T); curl -sw '%{http_code}\\n' -o /dev/null --max-time 2 http://$FIRST_EIP; sleep 2; done"
confirm "Trigger node replacement (mode=$MODE) now?"

if [[ "$MODE" == "version" ]]; then
  aws eks update-nodegroup-version \
    --cluster-name "$CLUSTER_NAME" \
    --nodegroup-name "$NG" \
    --region "$AWS_REGION" \
    --force
  log "Update initiated. Watch:"
  echo "  watch 'aws eks describe-nodegroup --cluster-name $CLUSTER_NAME --nodegroup-name $NG --region $AWS_REGION --query nodegroup.status'"
else
  ASG=$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" \
    --nodegroup-name "$NG" --region "$AWS_REGION" \
    --query 'nodegroup.resources.autoScalingGroups[0].name' --output text)
  INST=$(aws ec2 describe-instances --region "$AWS_REGION" \
    --filters "Name=tag:aws:autoscaling:groupName,Values=$ASG" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text)
  log "ASG=$ASG  will terminate instance=$INST"
  aws autoscaling terminate-instance-in-auto-scaling-group \
    --instance-id "$INST" \
    --no-should-decrement-desired-capacity \
    --region "$AWS_REGION" \
    --query 'Activity.[ActivityId,StatusCode,Description]' --output text
  log "Watch replacement:"
  echo "  kubectl get nodes -w"
fi
