#!/bin/bash
set -x
dnf install -y httpd
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
IID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)
cat > /var/www/html/index.html <<HTML
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>Kenya Telco Portal</title></head>
<body style="font-family:sans-serif;background:__BG__;color:#fff;padding:40px">
<h1>Kenya Telco Customer Portal</h1>
<p>Environment: __ENV__</p><p>Version: __VERSION__</p><p>Instance: $IID ($AZ)</p>
</body></html>
HTML
echo "OK __VERSION__" > /var/www/html/health
systemctl enable --now httpd
dnf install -y amazon-cloudwatch-agent || true
cat > /opt/aws/amazon-cloudwatch-agent/etc/config.json <<'CW'
{"metrics":{"namespace":"BlueGreen","append_dimensions":{"InstanceId":"${aws:InstanceId}"},
 "metrics_collected":{"mem":{"measurement":["mem_used_percent"]}}}}
CW
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/etc/config.json || true
