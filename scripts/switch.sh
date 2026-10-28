#!/bin/bash
# Usage: ./scripts/switch.sh <blue_weight> <green_weight>   e.g. 90 10 | 0 100 | 100 0 (rollback)
set -euo pipefail
source ~/bg.env
B=$1; G=$2
if [ "$G" -gt 0 ]; then
  TOTAL=$(aws elbv2 describe-target-health --target-group-arn $TG_GREEN --query 'length(TargetHealthDescriptions)' --output text)
  BAD=$(aws elbv2 describe-target-health --target-group-arn $TG_GREEN --query 'length(TargetHealthDescriptions[?TargetHealth.State!=`healthy`])' --output text)
  if [ "$TOTAL" -eq 0 ] || [ "$BAD" -ne 0 ]; then echo "ABORT: Green not fully healthy ($BAD/$TOTAL unhealthy)"; exit 1; fi
fi
aws elbv2 modify-listener --listener-arn $PROD_LISTENER --default-actions "[{\"Type\":\"forward\",\"ForwardConfig\":{\"TargetGroups\":[{\"TargetGroupArn\":\"$TG_BLUE\",\"Weight\":$B},{\"TargetGroupArn\":\"$TG_GREEN\",\"Weight\":$G}]}}]" >/dev/null
echo "$(date -u +%FT%TZ) weights -> blue=$B green=$G" | tee -a deploy.log
