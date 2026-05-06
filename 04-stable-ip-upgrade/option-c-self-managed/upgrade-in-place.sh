#!/usr/bin/env bash
# Force-replace the ASG's single instance; the pre-attached ENI means the new
# instance boots with the same primary private IP.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../00-prerequisites/env.sh"

ASG_NAME="${1:?ASG name required, e.g. eks-stable-asg-01}"

INSTANCE_ID=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" --region "$AWS_REGION" \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)
OLD_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$AWS_REGION" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
log "current instance $INSTANCE_ID  IP $OLD_IP"

confirm "Terminate instance $INSTANCE_ID and let ASG replace (ENI should stay)?"

aws autoscaling terminate-instance-in-auto-scaling-group \
  --instance-id "$INSTANCE_ID" \
  --no-should-decrement-desired-capacity \
  --region "$AWS_REGION"

log "Waiting for ASG to launch replacement..."
for i in {1..60}; do
  NEW_ID=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" --region "$AWS_REGION" \
    --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)
  [[ -n "$NEW_ID" && "$NEW_ID" != "$INSTANCE_ID" && "$NEW_ID" != "None" ]] && break
  sleep 5
done
NEW_IP=$(aws ec2 describe-instances --instance-ids "$NEW_ID" --region "$AWS_REGION" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
log "new instance $NEW_ID  IP $NEW_IP"

if [[ "$OLD_IP" == "$NEW_IP" ]]; then
  ok "IP preserved: $NEW_IP"
else
  err "IP changed: $OLD_IP -> $NEW_IP  (check ENI attachment in LaunchTemplate)"
  exit 1
fi
