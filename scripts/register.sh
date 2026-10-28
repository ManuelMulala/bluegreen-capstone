#!/bin/bash
# Usage: ./scripts/register.sh <blue|green>
set -euo pipefail
source ~/bg.env
COLOR=$1; TG_VAR="TG_$(echo "$COLOR" | tr a-z A-Z)"; TG=${!TG_VAR}
IDS=$(aws ec2 describe-instances --filters Name=tag:Env,Values=$COLOR Name=instance-state-name,Values=pending,running --query 'Reservations[].Instances[].InstanceId' --output text)
aws ec2 wait instance-running --instance-ids $IDS
aws elbv2 register-targets --target-group-arn $TG --targets $(for i in $IDS; do printf 'Id=%s ' $i; done)
echo "Registered $IDS -> bg-tg-$COLOR"
