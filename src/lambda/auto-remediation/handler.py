"""
Auto-remediation Lambda triggered by Security Hub findings.
Supports: S3 public access, unrestricted security groups, unencrypted resources.
"""
import json
import logging
import boto3
from typing import Any

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client("s3")
ec2 = boto3.client("ec2")
sns = boto3.client("sns")
sh = boto3.client("securityhub")


ALERT_TOPIC = "arn:aws:sns:us-east-1:ACCOUNT_ID:prod-security-alerts"

REMEDIATORS = {}


def remediator(finding_type: str):
    def decorator(fn):
        REMEDIATORS[finding_type] = fn
        return fn
    return decorator


def lambda_handler(event: dict, context: Any) -> dict:
    findings = event.get("detail", {}).get("findings", [])
    results = []

    for finding in findings:
        finding_id = finding.get("Id", "unknown")
        product_fields = finding.get("ProductFields", {})
        finding_type = _extract_finding_type(finding)

        logger.info(f"Processing finding: {finding_id}, type: {finding_type}")

        handler_fn = REMEDIATORS.get(finding_type)
        if handler_fn:
            try:
                result = handler_fn(finding)
                _update_finding_workflow(finding_id, finding.get("ProductArn", ""), "RESOLVED", result)
                results.append({"finding_id": finding_id, "status": "remediated", "detail": result})
            except Exception as e:
                logger.error(f"Remediation failed for {finding_id}: {e}")
                _send_alert(finding, str(e))
                results.append({"finding_id": finding_id, "status": "failed", "error": str(e)})
        else:
            logger.info(f"No remediator for type: {finding_type}, sending alert")
            _send_alert(finding, "No automated remediation available")
            results.append({"finding_id": finding_id, "status": "alerted"})

    return {"statusCode": 200, "body": json.dumps(results)}


@remediator("Software and Configuration Checks/AWS Security Best Practices/S3_BUCKET_PUBLIC_READ_PROHIBITED")
def remediate_s3_public_read(finding: dict) -> str:
    bucket = _get_resource_id(finding, "AwsS3Bucket")
    s3.put_public_access_block(
        Bucket=bucket,
        PublicAccessBlockConfiguration={
            "BlockPublicAcls": True,
            "IgnorePublicAcls": True,
            "BlockPublicPolicy": True,
            "RestrictPublicBuckets": True,
        },
    )
    logger.info(f"Blocked public access for bucket: {bucket}")
    return f"Blocked public access on S3 bucket: {bucket}"


@remediator("Software and Configuration Checks/AWS Security Best Practices/S3_BUCKET_PUBLIC_WRITE_PROHIBITED")
def remediate_s3_public_write(finding: dict) -> str:
    return remediate_s3_public_read(finding)


@remediator("Software and Configuration Checks/Industry and Regulatory Standards/CIS AWS Foundations Benchmark/sg-ssh-restricted")
def remediate_sg_unrestricted_ssh(finding: dict) -> str:
    sg_id = _get_resource_id(finding, "AwsEc2SecurityGroup")
    ec2.revoke_security_group_ingress(
        GroupId=sg_id,
        IpPermissions=[{
            "IpProtocol": "tcp",
            "FromPort": 22,
            "ToPort": 22,
            "IpRanges": [{"CidrIp": "0.0.0.0/0"}],
        }],
    )
    ec2.revoke_security_group_ingress(
        GroupId=sg_id,
        IpPermissions=[{
            "IpProtocol": "tcp",
            "FromPort": 22,
            "ToPort": 22,
            "Ipv6Ranges": [{"CidrIpv6": "::/0"}],
        }],
    )
    logger.info(f"Revoked unrestricted SSH from security group: {sg_id}")
    return f"Revoked 0.0.0.0/0 SSH ingress from SG: {sg_id}"


@remediator("Software and Configuration Checks/AWS Security Best Practices/ENCRYPTED_VOLUMES")
def remediate_unencrypted_volume(finding: dict) -> str:
    volume_id = _get_resource_id(finding, "AwsEc2Volume")
    _send_alert(finding, f"Unencrypted EBS volume detected: {volume_id}. Manual remediation required — create encrypted snapshot and replace volume.")
    return f"Alert sent for unencrypted volume: {volume_id}"


def _extract_finding_type(finding: dict) -> str:
    types = finding.get("Types", [])
    return types[0] if types else "Unknown"


def _get_resource_id(finding: dict, resource_type: str) -> str:
    resources = finding.get("Resources", [])
    for r in resources:
        if r.get("Type") == resource_type:
            return r.get("Id", "").split(":")[-1].split("/")[-1]
    raise ValueError(f"Resource type {resource_type} not found in finding")


def _update_finding_workflow(finding_id: str, product_arn: str, status: str, note: str):
    try:
        sh.batch_update_findings(
            FindingIdentifiers=[{"Id": finding_id, "ProductArn": product_arn}],
            Workflow={"Status": status},
            Note={"Text": f"Auto-remediated: {note}", "UpdatedBy": "auto-remediation-lambda"},
        )
    except Exception as e:
        logger.warning(f"Failed to update finding workflow: {e}")


def _send_alert(finding: dict, message: str):
    try:
        sns.publish(
            TopicArn=ALERT_TOPIC,
            Subject=f"Security Finding: {finding.get('Title', 'Unknown')}",
            Message=json.dumps({
                "finding_id": finding.get("Id"),
                "title": finding.get("Title"),
                "severity": finding.get("Severity", {}).get("Label"),
                "account": finding.get("AwsAccountId"),
                "message": message,
            }, indent=2),
        )
    except Exception as e:
        logger.error(f"Failed to send SNS alert: {e}")
