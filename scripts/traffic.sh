#!/bin/bash
# Sends a request every 0.5s and prints which environment answered.
source ~/bg.env
while true; do
  echo "$(date +%T) $(curl -s -m 2 http://$ALB_DNS/ | grep -o 'Environment: [A-Z]*' || echo ERROR)"
  sleep 0.5
done
