#!/usr/bin/env bash
# Open the NodePort on the nodegroup's Security Group, scoped to a CIDR you pick.
# Prefer the NLB (方案 C) for external traffic; this is for scenario A validation only.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../00-prerequisites/env.sh"

log "Resolving nodegroup SG for cluster=$CLUSTER_NAME"
NG_NAME_RESOLVED=$(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" \
  --region "$AWS_REGION" --query 'nodegroups[0]' --output text)
[[ "$NG_NAME_RESOLVED" == "None" || -z "$NG_NAME_RESOLVED" ]] && { err "no nodegroup found"; exit 1; }

ASG_NAME=$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name "$NG_NAME_RESOLVED" --region "$AWS_REGION" \
  --query 'nodegroup.resources.autoScalingGroups[0].name' --output text)
INSTANCE_ID=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" --region "$AWS_REGION" \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)
SG_ID=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$AWS_REGION" \
  --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text)
log "Nodegroup SG: $SG_ID"

MY_IP=$(curl -s https://checkip.amazonaws.com | tr -d '\n')
DEFAULT_CIDR="${MY_IP}/32"
printf 'Source CIDR to allow TCP %s [default %s]: ' "$DEMO_NODEPORT" "$DEFAULT_CIDR"
read -r CIDR
CIDR="${CIDR:-$DEFAULT_CIDR}"

warn "Will authorize TCP $DEMO_NODEPORT from $CIDR on SG $SG_ID"
confirm "Proceed?"

aws ec2 authorize-security-group-ingress --region "$AWS_REGION" \
  --group-id "$SG_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=$DEMO_NODEPORT,ToPort=$DEMO_NODEPORT,IpRanges=[{CidrIp=$CIDR,Description=eks-demo-nodeport}]" \
  || warn "rule may already exist"
ok "done. Test with: curl http://<any-node-public-ip>:$DEMO_NODEPORT"
