#!/usr/bin/env bash
# Skeleton: pre-create N secondary ENIs in the cluster's private subnets, one per slot.
# Review before running; destructive counterpart not provided (ENI deletion must be manual).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../00-prerequisites/env.sh"

SLOTS="${SLOTS:-2}"   # total nodes
log "Will create $SLOTS ENIs, one per slot, tagged slot=<N>."

VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)

PRIV_SUBNETS=($(aws ec2 describe-subnets --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:kubernetes.io/role/internal-elb,Values=1" \
  --query 'Subnets[].SubnetId' --output text))
log "Private subnets: ${PRIV_SUBNETS[*]}"

# Nodegroup SG to attach the ENI to
NG=$(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'nodegroups[0]' --output text)
ASG=$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NG" \
  --region "$AWS_REGION" --query 'nodegroup.resources.autoScalingGroups[0].name' --output text)
INST=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
  --region "$AWS_REGION" --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)
SG=$(aws ec2 describe-instances --instance-ids "$INST" --region "$AWS_REGION" \
  --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text)
log "Will attach SG $SG to each ENI."

confirm "Create $SLOTS ENIs in private subnets?"
for slot in $(seq 1 "$SLOTS"); do
  subnet="${PRIV_SUBNETS[$(( (slot-1) % ${#PRIV_SUBNETS[@]} ))]}"
  ENI_ID=$(aws ec2 create-network-interface --region "$AWS_REGION" \
    --subnet-id "$subnet" --groups "$SG" \
    --description "eks-stable-ip slot=$slot" \
    --tag-specifications "ResourceType=network-interface,Tags=[{Key=Owner,Value=eks-stable-ip},{Key=slot,Value=$slot},{Key=cluster,Value=$CLUSTER_NAME}]" \
    --query 'NetworkInterface.NetworkInterfaceId' --output text)
  IP=$(aws ec2 describe-network-interfaces --region "$AWS_REGION" \
    --network-interface-ids "$ENI_ID" \
    --query 'NetworkInterfaces[0].PrivateIpAddress' --output text)
  ok "slot=$slot subnet=$subnet ENI=$ENI_ID privateIP=$IP"
done
ok "Done. Reference these ENIs from the LaunchTemplate UserData by slot tag."
