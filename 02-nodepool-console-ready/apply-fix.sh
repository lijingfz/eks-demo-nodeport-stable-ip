#!/usr/bin/env bash
# Idempotently applies the fixes needed for AWS Console to create a nodegroup.
#
# Why every step exists (see POSTMORTEM.md P1, P2, P3 for full context):
#   1) Node IAM Role — Console's "Node IAM role" dropdown only shows roles with
#      the right trust + managed policies. Created via CloudFormation.
#      P1: AmazonEBSCSIDriverPolicy lives under service-role/, not policy/.
#          If iam-noderole.yaml is ever edited, double-check ARN paths with
#          `aws iam list-policies --scope AWS --query 'Policies[?PolicyName==\`X\`].Arn'`.
#   2) Subnet tags — eksctl 0.219 + EKS 1.35 creates VPC/subnets but does NOT
#      auto-tag `kubernetes.io/cluster/<name>=shared`. Without that tag the
#      Console node-group creation fails with "subnets are not tagged correctly".
#      This script ALWAYS tags (belt-and-suspenders); a no-op if already tagged.
#      P3: iterate one subnet at a time so tab-separated output from the CLI
#          doesn't get fed as a single resource-id.
#   3) Print Console-ready parameters.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../00-prerequisites/env.sh"

STACK_NAME="eks-demo-node-iam-role"

log "Step 1/3: ensure Node IAM Role via CloudFormation stack '$STACK_NAME'"
confirm "Create/update IAM Role 'eksDemoNodeRole'?"
aws cloudformation deploy \
  --region "$AWS_REGION" \
  --template-file "$SCRIPT_DIR/iam-noderole.yaml" \
  --stack-name "$STACK_NAME" \
  --capabilities CAPABILITY_NAMED_IAM
NODE_ROLE_ARN=$(aws cloudformation describe-stacks \
  --region "$AWS_REGION" --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='RoleArn'].OutputValue" --output text)
ok "Node IAM Role: $NODE_ROLE_ARN"

log "Step 2/3: ensure subnet tagging for cluster $CLUSTER_NAME (always idempotent)"
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)
log "VPC: $VPC_ID"

# Always add the cluster tag to every subnet in the VPC. Observed on 2026-05-06
# that eksctl 0.219 does NOT emit this tag, unlike older versions.
log "Tagging all subnets with kubernetes.io/cluster/$CLUSTER_NAME=shared ..."
for s in $(aws ec2 describe-subnets --region "$AWS_REGION" \
             --filters "Name=vpc-id,Values=$VPC_ID" \
             --query 'Subnets[].SubnetId' --output text | tr '\t' '\n'); do
  aws ec2 create-tags --region "$AWS_REGION" --resources "$s" --tags \
    "Key=kubernetes.io/cluster/$CLUSTER_NAME,Value=shared" >/dev/null
  echo "  tagged $s"
done

# Print a summary of private vs public subnets so the user can pick in Console.
PRIVATE_SUBNETS=$(aws ec2 describe-subnets --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:kubernetes.io/role/internal-elb,Values=1" \
  --query 'Subnets[].SubnetId' --output text | tr '\t' ' ')
PUBLIC_SUBNETS=$(aws ec2 describe-subnets --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:kubernetes.io/role/elb,Values=1" \
  --query 'Subnets[].SubnetId' --output text | tr '\t' ' ')
ok "Private subnets: $PRIVATE_SUBNETS"
ok "Public subnets:  $PUBLIC_SUBNETS"

log "Step 3/3: console parameters for nodegroup creation"
cat <<EOF

${COLOR_GRN}Open: https://console.aws.amazon.com/eks/home?region=$AWS_REGION#/clusters/$CLUSTER_NAME${COLOR_RST}

-> Add node group -> use these values:

  Name:            eks-demo-ng-console
  Node IAM role:   eksDemoNodeRole
                   (ARN: $NODE_ROLE_ARN)
  AMI type:        Amazon Linux 2023 (AL2023_x86_64_STANDARD)
  Capacity type:   On-Demand
  Instance types:  t3.large
  Disk size:       50 GiB
  Desired / Min / Max:  2 / 2 / 4
  Subnets:         (choose from PRIVATE list above; do not mix private and public)
                   $PRIVATE_SUBNETS
  Launch template: (leave empty)
  SSH:             disabled

If creation still fails, capture the error with:
  aws cloudformation describe-stack-events \\
    --region $AWS_REGION \\
    --stack-name eksctl-$CLUSTER_NAME-nodegroup-eks-demo-ng-console \\
    --query 'StackEvents[?ResourceStatus==\`CREATE_FAILED\`]'
EOF
