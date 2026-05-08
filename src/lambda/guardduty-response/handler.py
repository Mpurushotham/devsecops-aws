"""
GuardDuty finding response Lambda.
Triggered by EventBridge on GuardDuty findings >= HIGH severity.
Actions: isolate EC2 instances, block IPs via WAF, notify security team.
"""
import json
import logging
import os
import boto3
from datetime import datetime

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ec2  = boto3.client("ec2")
wafv2 = boto3.client("wafv2")
sns  = boto3.client("sns")
ssm  = boto3.client("ssm")

ALERT_TOPIC  = os.environ.get("ALERT_TOPIC_ARN", "")
IP_SET_ID    = os.environ.get("WAF_IP_SET_ID", "")
IP_SET_NAME  = os.environ.get("WAF_IP_SET_NAME", "blocked-ips")
ISOLATION_SG = os.environ.get("ISOLATION_SG_ID", "")


def lambda_handler(event: dict, context) -> dict:
    finding = event.get("detail", {})
    finding_type  = finding.get("type", "")
    severity      = finding.get("severity", 0)
    account_id    = finding.get("accountId", "")
    finding_id    = finding.get("id", "")

    logger.info(f"GuardDuty finding: {finding_id}, type: {finding_type}, severity: {severity}")

    actions_taken = []

    if severity >= 7.0:
        if "UnauthorizedAccess" in finding_type or "Backdoor" in finding_type:
            resource = finding.get("resource", {})
            if resource.get("resourceType") == "Instance":
                instance_id = resource.get("instanceDetails", {}).get("instanceId", "")
                if instance_id:
                    result = _isolate_instance(instance_id, finding_id)
                    actions_taken.append(result)

        if "Recon" in finding_type or "PortProbe" in finding_type:
            remote_ips = _extract_remote_ips(finding)
            for ip in remote_ips[:10]:
                result = _block_ip_in_waf(ip, finding_id)
                actions_taken.append(result)

        if "CryptoCurrency" in finding_type or "Trojan" in finding_type:
            resource = finding.get("resource", {})
            instance_id = resource.get("instanceDetails", {}).get("instanceId", "")
            if instance_id:
                _isolate_instance(instance_id, finding_id)
                _create_forensic_snapshot(instance_id, finding_id)
                actions_taken.append(f"Isolated and snapshotted instance: {instance_id}")

    _send_alert(finding, actions_taken)
    return {"statusCode": 200, "actions": actions_taken}


def _isolate_instance(instance_id: str, finding_id: str) -> str:
    if not ISOLATION_SG:
        return f"Isolation SG not configured, skipping for {instance_id}"
    try:
        instance = ec2.describe_instances(InstanceIds=[instance_id])
        current_sgs = [
            sg["GroupId"]
            for r in instance["Reservations"]
            for i in r["Instances"]
            for sg in i.get("SecurityGroups", [])
        ]
        ec2.modify_instance_attribute(
            InstanceId=instance_id,
            Groups=[ISOLATION_SG],
        )
        ssm.put_parameter(
            Name=f"/devsecops/isolation/{instance_id}/original_sgs",
            Value=json.dumps(current_sgs),
            Type="String",
            Overwrite=True,
        )
        ec2.create_tags(
            Resources=[instance_id],
            Tags=[
                {"Key": "SecurityStatus", "Value": "ISOLATED"},
                {"Key": "IsolationFinding", "Value": finding_id},
                {"Key": "IsolationTime", "Value": datetime.utcnow().isoformat()},
            ],
        )
        logger.info(f"Isolated instance {instance_id}")
        return f"Isolated EC2 instance: {instance_id}"
    except Exception as e:
        logger.error(f"Failed to isolate {instance_id}: {e}")
        return f"Isolation failed for {instance_id}: {e}"


def _block_ip_in_waf(ip: str, finding_id: str) -> str:
    if not IP_SET_ID:
        return f"WAF IP Set not configured, skipping {ip}"
    try:
        current = wafv2.get_ip_set(
            Name=IP_SET_NAME,
            Scope="REGIONAL",
            Id=IP_SET_ID,
        )
        addresses = current["IPSet"]["Addresses"]
        cidr = f"{ip}/32" if ":" not in ip else f"{ip}/128"
        if cidr not in addresses:
            addresses.append(cidr)
            wafv2.update_ip_set(
                Name=IP_SET_NAME,
                Scope="REGIONAL",
                Id=IP_SET_ID,
                Addresses=addresses,
                LockToken=current["LockToken"],
            )
            logger.info(f"Blocked IP in WAF: {ip}")
            return f"Blocked IP in WAF: {ip}"
        return f"IP already blocked: {ip}"
    except Exception as e:
        logger.error(f"Failed to block IP {ip}: {e}")
        return f"WAF block failed for {ip}: {e}"


def _create_forensic_snapshot(instance_id: str, finding_id: str) -> str:
    try:
        volumes = ec2.describe_volumes(
            Filters=[{"Name": "attachment.instance-id", "Values": [instance_id]}]
        )
        for vol in volumes.get("Volumes", []):
            ec2.create_snapshot(
                VolumeId=vol["VolumeId"],
                Description=f"Forensic snapshot - Finding: {finding_id}",
                TagSpecifications=[{
                    "ResourceType": "snapshot",
                    "Tags": [
                        {"Key": "Purpose", "Value": "ForensicSnapshot"},
                        {"Key": "FindingId", "Value": finding_id},
                        {"Key": "InstanceId", "Value": instance_id},
                    ],
                }],
            )
        return f"Forensic snapshots created for instance: {instance_id}"
    except Exception as e:
        return f"Snapshot failed for {instance_id}: {e}"


def _extract_remote_ips(finding: dict) -> list:
    ips = []
    service = finding.get("service", {})
    for action_type in ["networkConnectionAction", "portProbeAction"]:
        action = service.get("action", {}).get(action_type, {})
        details = action.get("remoteIpDetails", {})
        if details.get("ipAddressV4"):
            ips.append(details["ipAddressV4"])
        for probe in action.get("portProbeDetails", []):
            remote = probe.get("remoteIpDetails", {})
            if remote.get("ipAddressV4"):
                ips.append(remote["ipAddressV4"])
    return list(set(ips))


def _send_alert(finding: dict, actions: list):
    if not ALERT_TOPIC:
        return
    try:
        sns.publish(
            TopicArn=ALERT_TOPIC,
            Subject=f"[GuardDuty] {finding.get('type', 'Unknown')} - Severity {finding.get('severity', 0)}",
            Message=json.dumps({
                "finding_id": finding.get("id"),
                "type": finding.get("type"),
                "severity": finding.get("severity"),
                "account": finding.get("accountId"),
                "region": finding.get("region"),
                "description": finding.get("description"),
                "actions_taken": actions,
                "timestamp": datetime.utcnow().isoformat(),
            }, indent=2),
        )
    except Exception as e:
        logger.error(f"Failed to send alert: {e}")
