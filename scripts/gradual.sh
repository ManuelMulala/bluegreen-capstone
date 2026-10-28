#!/bin/bash
# Shifts traffic 10% -> 50% -> 100% Green, soaking 3 min at each step. Auto-rolls back on any bg-green-* alarm.
set -uo pipefail
source ~/bg.env
for G in 10 50 100; do
  ./scripts/switch.sh $((100-G)) $G || exit 1
  echo "Soaking at ${G}% Green for 3 minutes..."
  for i in $(seq 18); do
    A=$(aws cloudwatch describe-alarms --alarm-name-prefix bg-green- --state-value ALARM --query 'MetricAlarms[].AlarmName' --output text)
    if [ -n "$A" ]; then echo "ALARM: $A -> rolling back"; ./scripts/switch.sh 100 0; exit 1; fi
    sleep 10
  done
done
echo "Green is serving 100% of traffic"
