#!/usr/bin/env bash
# Create a self-managed EKS node as a 1-instance ASG whose LaunchTemplate pins
# the primary ENI to a pre-created ENI. The ENI's private IP is what we want to
# survive across instance replacements.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../00-prerequisites/env.sh"

SUFFIX="${1:-01}"
ENI_NAME="eks-stable-primary-$SUFFIX"
LT_NAME="eks-stable-lt-$SUFFIX"
ASG_NAME="eks-stable-asg-$SUFFIX"

VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)
SUBNET=$(aws ec2 describe-subnets --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
            "Name=availability-zone,Values=$AZ_A" \
            "Name=tag:kubernetes.io/role/internal-elb,Values=1" \
  --query 'Subnets[0].SubnetId' --output text)
[[ "$SUBNET" == "None" ]] && { err "no private subnet found in $AZ_A"; exit 1; }

# Cluster SG is the canonical SG for self-managed nodes:
CLUSTER_SG=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)

log "Will create:"
log "  ENI    $ENI_NAME   in $SUBNET"
log "  LT     $LT_NAME"
log "  ASG    $ASG_NAME   (min=max=1)"
confirm "Proceed?"

# 1. ENI
ENI_ID=$(aws ec2 create-network-interface --region "$AWS_REGION" \
  --subnet-id "$SUBNET" --groups "$CLUSTER_SG" \
  --description "$ENI_NAME" \
  --tag-specifications "ResourceType=network-interface,Tags=[{Key=Name,Value=$ENI_NAME},{Key=cluster,Value=$CLUSTER_NAME}]" \
  --query 'NetworkInterface.NetworkInterfaceId' --output text)
IP=$(aws ec2 describe-network-interfaces --region "$AWS_REGION" \
  --network-interface-ids "$ENI_ID" --query 'NetworkInterfaces[0].PrivateIpAddress' --output text)
ok "ENI $ENI_ID  private IP $IP"

# 2. Get latest EKS-optimized AL2023 AMI
AMI=$(aws ssm get-parameter --region "$AWS_REGION" \
  --name "/aws/service/eks/optimized-ami/$CLUSTER_VERSION/amazon-linux-2023/x86_64/standard/recommended/image_id" \
  --query 'Parameter.Value' --output text)
log "AMI $AMI"

# 3. UserData that runs EKS bootstrap
B64_USERDATA=$(base64 <<EOF
#!/bin/bash
set -e
/etc/eks/bootstrap.sh "$CLUSTER_NAME" --kubelet-extra-args "--node-labels=stable-ip=primary"
EOF
)

# 4. LaunchTemplate data — note NetworkInterfaces pins the ENI
cat > /tmp/lt-data.json <<EOF
{
  "ImageId": "$AMI",
  "InstanceType": "t3.large",
  "UserData": "$B64_USERDATA",
  "IamInstanceProfile": { "Name": "eksDemoNodeRole" },
  "TagSpecifications": [{
    "ResourceType": "instance",
    "Tags": [
      {"Key":"Name","Value":"$ASG_NAME"},
      {"Key":"kubernetes.io/cluster/$CLUSTER_NAME","Value":"owned"}
    ]
  }],
  "NetworkInterfaces": [{
    "DeviceIndex": 0,
    "NetworkInterfaceId": "$ENI_ID"
  }]
}
EOF

LT_ID=$(aws ec2 create-launch-template --region "$AWS_REGION" \
  --launch-template-name "$LT_NAME" \
  --launch-template-data file:///tmp/lt-data.json \
  --query 'LaunchTemplate.LaunchTemplateId' --output text)
ok "LT $LT_ID"

# 5. ASG (min=max=1)
aws autoscaling create-auto-scaling-group --region "$AWS_REGION" \
  --auto-scaling-group-name "$ASG_NAME" \
  --launch-template "LaunchTemplateId=$LT_ID,Version=\$Latest" \
  --min-size 1 --max-size 1 --desired-capacity 1 \
  --vpc-zone-identifier "$SUBNET" \
  --tags "Key=Name,Value=$ASG_NAME,PropagateAtLaunch=true" \
         "Key=kubernetes.io/cluster/$CLUSTER_NAME,Value=owned,PropagateAtLaunch=true"
ok "ASG $ASG_NAME created, pinned to ENI $ENI_ID (IP $IP)"

log "kubelet will register the node automatically if aws-auth ConfigMap already maps eksDemoNodeRole."
log "If not, run: eksctl create iamidentitymapping --cluster $CLUSTER_NAME --region $AWS_REGION \\"
log "  --arn arn:aws:iam::$AWS_ACCOUNT_ID:role/eksDemoNodeRole --group system:bootstrappers --group system:nodes --username system:node:{{EC2PrivateDNSName}}"
