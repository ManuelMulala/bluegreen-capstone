#!/bin/bash
# Usage: ./scripts/launch.sh <blue|green> <version>
set -euo pipefail
source ~/bg.env
COLOR=$1; VERSION=$2; ENV_UP=$(echo "$COLOR" | tr a-z A-Z)
if [ "$COLOR" = blue ]; then BG="#1f4e9c"; else BG="#1e7d3a"; fi
sed "s/__ENV__/$ENV_UP/g; s/__VERSION__/$VERSION/g; s/__BG__/$BG/g" scripts/userdata.sh > /tmp/ud-$COLOR.sh
for SUBNET in $SUBNET_A $SUBNET_B; do
  aws ec2 run-instances --image-id $AMI_ID --instance-type t3.micro --subnet-id $SUBNET \
    --security-group-ids $WEB_SG --iam-instance-profile Name=bg-web-profile \
    --associate-public-ip-address --user-data file:///tmp/ud-$COLOR.sh \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=web-$COLOR},{Key=Env,Value=$COLOR},{Key=Version,Value=$VERSION}]" \
    --query 'Instances[0].InstanceId' --output text
done
