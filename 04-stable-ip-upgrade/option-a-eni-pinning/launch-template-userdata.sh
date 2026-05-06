#!/usr/bin/env bash
# ======================================================================
# This file is INJECTED into the EC2 LaunchTemplate as UserData.
# It is NOT meant to be run from your laptop.
# It finds a pre-created ENI by `slot` tag and attaches it as eth1.
# ======================================================================
set -euo pipefail
exec > >(tee /var/log/eni-attach.log) 2>&1

IMDS_TOKEN=$(curl -sX PUT 'http://169.254.169.254/latest/api/token' \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 300')
curl_imds() { curl -sH "X-aws-ec2-metadata-token: $IMDS_TOKEN" "http://169.254.169.254/latest/$1"; }

INSTANCE_ID=$(curl_imds meta-data/instance-id)
REGION=$(curl_imds dynamic/instance-identity/document | grep -oE '"region"\s*:\s*"[^"]+"' | cut -d'"' -f4)
AZ=$(curl_imds meta-data/placement/availability-zone)

SLOT=$(aws ec2 describe-tags --region "$REGION" \
  --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=slot" \
  --query 'Tags[0].Value' --output text)
[[ -z "$SLOT" || "$SLOT" == "None" ]] && { echo "no slot tag on instance; skipping ENI attach"; exit 0; }

ENI_ID=$(aws ec2 describe-network-interfaces --region "$REGION" \
  --filters "Name=tag:Owner,Values=eks-stable-ip" \
            "Name=tag:slot,Values=$SLOT" \
            "Name=availability-zone,Values=$AZ" \
            "Name=status,Values=available" \
  --query 'NetworkInterfaces[0].NetworkInterfaceId' --output text)
[[ -z "$ENI_ID" || "$ENI_ID" == "None" ]] && { echo "no free ENI for slot=$SLOT AZ=$AZ; abort"; exit 1; }

echo "Attaching $ENI_ID (slot=$SLOT) to $INSTANCE_ID as device-index 1"
aws ec2 attach-network-interface --region "$REGION" \
  --network-interface-id "$ENI_ID" \
  --instance-id "$INSTANCE_ID" \
  --device-index 1

# Bring the second NIC up and avoid VPC CNI claiming it for pod IPs:
#   - exclude eth1 from ec2-net-utils policy routing interference
#   - configure MAX_ENI / WARM_ENI_TARGET on aws-node DaemonSet instead

# After attach, run the standard EKS bootstrap. (Managed nodegroups handle this
# for you; for self-managed you must call /etc/eks/bootstrap.sh here.)
# /etc/eks/bootstrap.sh <cluster-name> --kubelet-extra-args "--node-labels=stable-ip=true"
