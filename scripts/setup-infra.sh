#!/bin/bash
# =============================================================================
# setup-infra.sh - Builds the full Blue-Green environment from scratch (eu-west-1)
#
# Creates: security groups, IAM role/instance profile, Blue + Green target groups,
#          ALB with weighted prod listener (:80) and Green-only test listener (:8080),
#          SNS topic, 4 CloudWatch alarms, dashboard, rollback Lambda + EventBridge rule.
# Does NOT launch instances - use launch.sh / register.sh afterwards.
#
# Usage:   ./scripts/setup-infra.sh you@example.com
# Output:  all resource IDs saved to ~/bg.env (source it in any new terminal)
# Compatible with macOS bash 3.2 and AWS CloudShell. Run from the repo root.
# =============================================================================
set -euo pipefail

EMAIL=${1:?Usage: ./scripts/setup-infra.sh <alert-email>}
export AWS_REGION=eu-west-1 AWS_DEFAULT_REGION=eu-west-1 AWS_PAGER=""

# Safety: refuse to run if the environment already exists (avoids duplicates)
if aws elbv2 describe-load-balancers --names bg-alb >/dev/null 2>&1; then
  echo "bg-alb already exists. Tear down first (see README > Teardown) or use the existing ~/bg.env."
  exit 1
fi

# --- Environment file ---------------------------------------------------------
cat > ~/bg.env <<'EOF'
export AWS_REGION=eu-west-1 AWS_DEFAULT_REGION=eu-west-1 AWS_PAGER=""
save() { echo "export $1=\"$2\"" >> ~/bg.env; export $1="$2"; echo "$1=$2"; }
EOF
source ~/bg.env

echo "== Step 0: account, network, AMI"
save ACCOUNT  "$(aws sts get-caller-identity --query Account --output text)"
save VPC      "$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)"
save SUBNET_A "$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC Name=default-for-az,Values=true --query 'Subnets[0].SubnetId' --output text)"
save SUBNET_B "$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC Name=default-for-az,Values=true --query 'Subnets[1].SubnetId' --output text)"
# Resolved once and reused for Blue and Green -> guaranteed AMI parity
save AMI_ID   "$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query Parameter.Value --output text)"

echo "== Step 1a: security groups (shared by Blue and Green)"
save ALB_SG "$(aws ec2 create-security-group --group-name bg-alb-sg --description 'Blue-Green ALB' --vpc-id $VPC --query GroupId --output text)"
aws ec2 authorize-security-group-ingress --group-id $ALB_SG --protocol tcp --port 80   --cidr 0.0.0.0/0 >/dev/null
aws ec2 authorize-security-group-ingress --group-id $ALB_SG --protocol tcp --port 8080 --cidr 0.0.0.0/0 >/dev/null
save WEB_SG "$(aws ec2 create-security-group --group-name bg-web-sg --description 'Web tier, shared by Blue and Green' --vpc-id $VPC --query GroupId --output text)"
# Web instances accept HTTP only from the ALB. Default egress (all) is kept so dnf/SSM work.
aws ec2 authorize-security-group-ingress --group-id $WEB_SG --protocol tcp --port 80 --source-group $ALB_SG >/dev/null

echo "== Step 1b: IAM role + instance profile (SSM + CloudWatch agent)"
if ! aws iam get-role --role-name bg-web-role >/dev/null 2>&1; then
  aws iam create-role --role-name bg-web-role --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam attach-role-policy --role-name bg-web-role --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  aws iam attach-role-policy --role-name bg-web-role --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy
fi
if ! aws iam get-instance-profile --instance-profile-name bg-web-profile >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name bg-web-profile >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name bg-web-profile --role-name bg-web-role
fi

echo "== Step 1c / 3: target groups with health checks"
create_tg() {
  aws elbv2 create-target-group --name "$1" --protocol HTTP --port 80 --vpc-id $VPC --target-type instance \
    --health-check-path /health --health-check-interval-seconds 10 --health-check-timeout-seconds 5 \
    --healthy-threshold-count 2 --unhealthy-threshold-count 2 --matcher HttpCode=200 \
    --query 'TargetGroups[0].TargetGroupArn' --output text
}
save TG_BLUE  "$(create_tg bg-tg-blue)"
save TG_GREEN "$(create_tg bg-tg-green)"

echo "== Step 1d: ALB, weighted prod listener (:80), Green-only test listener (:8080)"
save ALB_ARN "$(aws elbv2 create-load-balancer --name bg-alb --subnets $SUBNET_A $SUBNET_B --security-groups $ALB_SG --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
save ALB_DNS "$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN --query 'LoadBalancers[0].DNSName' --output text)"
save PROD_LISTENER "$(aws elbv2 create-listener --load-balancer-arn $ALB_ARN --protocol HTTP --port 80 \
  --default-actions "[{\"Type\":\"forward\",\"ForwardConfig\":{\"TargetGroups\":[{\"TargetGroupArn\":\"$TG_BLUE\",\"Weight\":100},{\"TargetGroupArn\":\"$TG_GREEN\",\"Weight\":0}]}}]" \
  --query 'Listeners[0].ListenerArn' --output text)"
save TEST_LISTENER "$(aws elbv2 create-listener --load-balancer-arn $ALB_ARN --protocol HTTP --port 8080 \
  --default-actions Type=forward,TargetGroupArn=$TG_GREEN --query 'Listeners[0].ListenerArn' --output text)"

echo "== Step 4a: SNS topic + CloudWatch alarms"
save TOPIC "$(aws sns create-topic --name bg-alerts --query TopicArn --output text)"
aws sns subscribe --topic-arn $TOPIC --protocol email --notification-endpoint "$EMAIL" >/dev/null
echo "   -> Confirm the subscription email sent to $EMAIL"

LB_DIM=${ALB_ARN##*:loadbalancer/}
TGB_DIM=targetgroup/${TG_BLUE##*:targetgroup/}
TGG_DIM=targetgroup/${TG_GREEN##*:targetgroup/}
G="Name=LoadBalancer,Value=$LB_DIM Name=TargetGroup,Value=$TGG_DIM"
COMMON="--namespace AWS/ApplicationELB --period 60 --treat-missing-data notBreaching --alarm-actions $TOPIC --ok-actions $TOPIC"

# bg-green-* alarms trigger auto-rollback; bg-alb-5xx is notify-only
aws cloudwatch put-metric-alarm --alarm-name bg-green-5xx       --metric-name HTTPCode_Target_5XX_Count --dimensions $G --statistic Sum     --evaluation-periods 1 --threshold 5 --comparison-operator GreaterThanOrEqualToThreshold $COMMON
aws cloudwatch put-metric-alarm --alarm-name bg-green-unhealthy --metric-name UnHealthyHostCount        --dimensions $G --statistic Maximum --evaluation-periods 1 --threshold 1 --comparison-operator GreaterThanOrEqualToThreshold $COMMON
aws cloudwatch put-metric-alarm --alarm-name bg-green-latency   --metric-name TargetResponseTime        --dimensions $G --extended-statistic p90 --evaluation-periods 2 --threshold 1 --comparison-operator GreaterThanThreshold $COMMON
aws cloudwatch put-metric-alarm --alarm-name bg-alb-5xx         --metric-name HTTPCode_ELB_5XX_Count    --dimensions Name=LoadBalancer,Value=$LB_DIM --statistic Sum --evaluation-periods 1 --threshold 5 --comparison-operator GreaterThanOrEqualToThreshold $COMMON

echo "== Step 4a: CloudWatch dashboard (docs/dashboard.json)"
mkdir -p docs
tg_metric() { # metric, tg-dim, label, color
  echo "[\"AWS/ApplicationELB\",\"$1\",\"TargetGroup\",\"$2\",\"LoadBalancer\",\"$LB_DIM\",{\"label\":\"$3\",\"color\":\"$4\"}]"
}
ALARM_PREFIX="arn:aws:cloudwatch:eu-west-1:${ACCOUNT}:alarm"
cat > docs/dashboard.json <<EOF
{
  "widgets": [
    {"type":"metric","x":0,"y":0,"width":12,"height":6,"properties":{"title":"Request count: Blue vs Green","region":"eu-west-1","view":"timeSeries","stat":"Sum","period":60,
      "metrics":[$(tg_metric RequestCount $TGB_DIM Blue '#1f4e9c'),$(tg_metric RequestCount $TGG_DIM Green '#1e7d3a')]}},
    {"type":"metric","x":12,"y":0,"width":12,"height":6,"properties":{"title":"Target 5XX errors","region":"eu-west-1","view":"timeSeries","stat":"Sum","period":60,
      "metrics":[$(tg_metric HTTPCode_Target_5XX_Count $TGB_DIM 'Blue 5XX' '#1f4e9c'),$(tg_metric HTTPCode_Target_5XX_Count $TGG_DIM 'Green 5XX' '#d62728')]}},
    {"type":"metric","x":0,"y":6,"width":12,"height":6,"properties":{"title":"Target response time p90 (s)","region":"eu-west-1","view":"timeSeries","stat":"p90","period":60,
      "metrics":[$(tg_metric TargetResponseTime $TGB_DIM 'Blue p90' '#1f4e9c'),$(tg_metric TargetResponseTime $TGG_DIM 'Green p90' '#1e7d3a')],
      "annotations":{"horizontal":[{"label":"Latency alarm (1s)","value":1}]}}},
    {"type":"metric","x":12,"y":6,"width":12,"height":6,"properties":{"title":"Healthy hosts","region":"eu-west-1","view":"timeSeries","stat":"Minimum","period":60,
      "metrics":[$(tg_metric HealthyHostCount $TGB_DIM 'Blue healthy' '#1f4e9c'),$(tg_metric HealthyHostCount $TGG_DIM 'Green healthy' '#1e7d3a'),$(tg_metric UnHealthyHostCount $TGG_DIM 'Green unhealthy' '#d62728')]}},
    {"type":"metric","x":0,"y":12,"width":12,"height":6,"properties":{"title":"EC2 CPU utilization (%)","region":"eu-west-1","view":"timeSeries","period":60,
      "metrics":[[{"expression":"SEARCH('{AWS/EC2,InstanceId} MetricName=\"CPUUtilization\"', 'Average', 60)","id":"cpu","label":""}]]}},
    {"type":"metric","x":12,"y":12,"width":12,"height":6,"properties":{"title":"Memory used (%), CloudWatch agent","region":"eu-west-1","view":"timeSeries","period":60,
      "metrics":[[{"expression":"SEARCH('{BlueGreen,InstanceId} MetricName=\"mem_used_percent\"', 'Average', 60)","id":"mem","label":""}]]}},
    {"type":"alarm","x":0,"y":18,"width":24,"height":3,"properties":{"title":"Deployment alarms","alarms":[
      "${ALARM_PREFIX}:bg-green-5xx","${ALARM_PREFIX}:bg-green-unhealthy","${ALARM_PREFIX}:bg-green-latency","${ALARM_PREFIX}:bg-alb-5xx"]}}
  ]
}
EOF
aws cloudwatch put-dashboard --dashboard-name bg-deployment --dashboard-body file://docs/dashboard.json >/dev/null

echo "== Step 5b: auto-rollback Lambda + EventBridge rule"
if ! aws iam get-role --role-name bg-rollback-role >/dev/null 2>&1; then
  aws iam create-role --role-name bg-rollback-role --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam attach-role-policy --role-name bg-rollback-role --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
fi
# Least privilege: may only modify THIS prod listener and publish to THIS topic
aws iam put-role-policy --role-name bg-rollback-role --policy-name rollback --policy-document \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"elasticloadbalancing:ModifyListener\",\"Resource\":\"${PROD_LISTENER}\"},{\"Effect\":\"Allow\",\"Action\":\"sns:Publish\",\"Resource\":\"${TOPIC}\"}]}"

(cd lambda && zip -q ../rollback.zip rollback.py)
echo "   waiting 15s for IAM propagation..."; sleep 15
ENV_VARS="Variables={LISTENER_ARN=${PROD_LISTENER},TG_BLUE=${TG_BLUE},TG_GREEN=${TG_GREEN},TOPIC_ARN=${TOPIC}}"
if aws lambda get-function --function-name bg-auto-rollback >/dev/null 2>&1; then
  aws lambda update-function-code --function-name bg-auto-rollback --zip-file fileb://rollback.zip >/dev/null
  aws lambda wait function-updated --function-name bg-auto-rollback
  aws lambda update-function-configuration --function-name bg-auto-rollback --environment "$ENV_VARS" >/dev/null
  save FN_ARN "$(aws lambda get-function --function-name bg-auto-rollback --query Configuration.FunctionArn --output text)"
else
  save FN_ARN "$(aws lambda create-function --function-name bg-auto-rollback --runtime python3.12 --handler rollback.handler \
    --zip-file fileb://rollback.zip --role arn:aws:iam::${ACCOUNT}:role/bg-rollback-role --timeout 30 \
    --environment "$ENV_VARS" --query FunctionArn --output text)"
fi
rm -f rollback.zip

save RULE_ARN "$(aws events put-rule --name bg-green-alarm-rollback \
  --event-pattern '{"source":["aws.cloudwatch"],"detail-type":["CloudWatch Alarm State Change"],"detail":{"alarmName":[{"prefix":"bg-green-"}],"state":{"value":["ALARM"]}}}' \
  --query RuleArn --output text)"
aws lambda add-permission --function-name bg-auto-rollback --statement-id eventbridge --action lambda:InvokeFunction \
  --principal events.amazonaws.com --source-arn ${RULE_ARN} >/dev/null 2>&1 || true
aws events put-targets --rule bg-green-alarm-rollback --targets Id=rollback,Arn=${FN_ARN} >/dev/null

echo
echo "Infrastructure ready. ALB: http://${ALB_DNS}"
echo "Next:  ./scripts/launch.sh blue v1.0 && ./scripts/register.sh blue"
echo "       ./scripts/launch.sh green v2.0 && ./scripts/register.sh green"
echo "       ./scripts/smoke-test.sh v2.0 && ./scripts/gradual.sh"
