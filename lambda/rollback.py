"""Auto-rollback: when any bg-green-* alarm enters ALARM, send 100% of production traffic back to Blue."""
import os
import boto3

elb = boto3.client("elbv2")
sns = boto3.client("sns")

def handler(event, context):
    alarm = event.get("detail", {}).get("alarmName", "manual-test")
    elb.modify_listener(
        ListenerArn=os.environ["LISTENER_ARN"],
        DefaultActions=[{"Type": "forward", "ForwardConfig": {"TargetGroups": [
            {"TargetGroupArn": os.environ["TG_BLUE"], "Weight": 100},
            {"TargetGroupArn": os.environ["TG_GREEN"], "Weight": 0},
        ]}}],
    )
    msg = f"AUTO-ROLLBACK: alarm {alarm} fired at {event.get('time', 'n/a')}. Production traffic is now 100% Blue."
    print(msg)
    sns.publish(TopicArn=os.environ["TOPIC_ARN"], Subject="Blue-Green auto-rollback", Message=msg)
    return {"rolledBack": True, "trigger": alarm}
