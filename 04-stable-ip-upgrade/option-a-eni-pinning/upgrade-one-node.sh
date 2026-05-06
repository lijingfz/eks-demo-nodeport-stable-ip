#!/usr/bin/env bash
# Upgrade one node while preserving its secondary-ENI private IP.
# Usage: ./upgrade-one-node.sh <node-name>
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../00-prerequisites/env.sh"

NODE="${1:?node name required}"
INSTANCE_ID=$(kubectl get node "$NODE" -o jsonpath='{.spec.providerID}' | awk -F/ '{print $NF}')
log "node=$NODE instance=$INSTANCE_ID"

SLOT=$(aws ec2 describe-tags --region "$AWS_REGION" \
  --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=slot" \
  --query 'Tags[0].Value' --output text)
log "slot=$SLOT"

ENI_ATTACH=$(aws ec2 describe-network-interfaces --region "$AWS_REGION" \
  --filters "Name=attachment.instance-id,Values=$INSTANCE_ID" \
            "Name=tag:slot,Values=$SLOT" \
  --query 'NetworkInterfaces[0].Attachment.AttachmentId' --output text)
ENI_ID=$(aws ec2 describe-network-interfaces --region "$AWS_REGION" \
  --filters "Name=attachment.instance-id,Values=$INSTANCE_ID" \
            "Name=tag:slot,Values=$SLOT" \
  --query 'NetworkInterfaces[0].NetworkInterfaceId' --output text)
log "attachment=$ENI_ATTACH eni=$ENI_ID"

confirm "Drain $NODE, detach ENI $ENI_ID, terminate $INSTANCE_ID (ASG will replace)?"

kubectl cordon "$NODE"
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --force --timeout=180s

aws ec2 detach-network-interface --region "$AWS_REGION" --attachment-id "$ENI_ATTACH" --force
for i in {1..30}; do
  status=$(aws ec2 describe-network-interfaces --region "$AWS_REGION" \
    --network-interface-ids "$ENI_ID" --query 'NetworkInterfaces[0].Status' --output text)
  [[ "$status" == "available" ]] && break
  sleep 4
done
ok "ENI detached"

aws ec2 terminate-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"
ok "old instance terminated; ASG will launch a replacement that re-attaches ENI $ENI_ID via UserData"

log "Watch:"
echo "  kubectl get nodes -w"
echo "  aws ec2 describe-network-interfaces --network-interface-ids $ENI_ID --query 'NetworkInterfaces[0].[Status,PrivateIpAddress,Attachment.InstanceId]'"
