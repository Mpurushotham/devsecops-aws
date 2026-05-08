# CIS AWS Foundations Benchmark v3.0 Mapping

## 1. Identity and Access Management

| CIS Control | Description | Implementation | Status |
|---|---|---|---|
| 1.1 | Root account MFA enabled | Config rule: `root-account-mfa-enabled` | Automated |
| 1.2 | No root access keys | Config rule: `iam-root-access-key-check` | Automated |
| 1.3 | IAM password policy | Config rule: `iam-password-policy` (14+ chars, complexity) | Automated |
| 1.4 | Access keys rotated every 90 days | Config rule: `access-keys-rotated` | Automated |
| 1.5 | Unused credentials disabled | Config rule: `iam-user-unused-credentials-check` | Automated |
| 1.10 | MFA for all IAM users | SCP + IAM policy condition | Automated |
| 1.14 | Hardware MFA for root | Manual verification required | Manual |
| 1.16 | IAM policies attached to groups/roles only | Config rule: `iam-user-no-policies-check` | Automated |

## 2. Storage

| CIS Control | Description | Implementation | Status |
|---|---|---|---|
| 2.1.1 | S3 no public access | Config rules: public read/write prohibited + auto-remediation | Automated |
| 2.1.2 | S3 MFA delete on sensitive buckets | Terraform module s3 (versioning enabled) | Automated |
| 2.1.3 | S3 bucket replication enabled | Config rule (optional) | Manual |
| 2.1.4 | S3 server-side encryption | Config rule: `s3-bucket-server-side-encryption-enabled` | Automated |
| 2.2.1 | EBS encryption by default | AWS account-level setting via Terraform | Automated |
| 2.3.1 | RDS encryption at rest | Config rule: `rds-storage-encrypted` | Automated |

## 3. Logging

| CIS Control | Description | Implementation | Status |
|---|---|---|---|
| 3.1 | CloudTrail enabled in all regions | Multi-region trail with Terraform | Automated |
| 3.2 | CloudTrail log file validation | `enable_log_file_validation = true` | Automated |
| 3.3 | CloudTrail S3 not public | S3 module with public access block | Automated |
| 3.4 | CloudTrail log encrypted with KMS | `kms_key_id` set in trail | Automated |
| 3.5 | CloudTrail integrated with CloudWatch | `cloud_watch_logs_group_arn` set | Automated |
| 3.6 | Config enabled in all regions | `aws_config_configuration_recorder` all_supported=true | Automated |
| 3.7 | Config S3 bucket access logging | S3 module with logging enabled | Automated |
| 3.9 | VPC flow logging enabled | Config rule: `vpc-flow-logs-enabled` | Automated |

## 4. Monitoring

| CIS Control | Description | Implementation | Status |
|---|---|---|---|
| 4.1 | Alarm for unauthorized API calls | CloudWatch alarm + metric filter | Automated |
| 4.2 | Alarm for console login without MFA | CloudWatch alarm + metric filter | Automated |
| 4.3 | Alarm for root account usage | CloudWatch alarm + metric filter | Automated |
| 4.4 | Alarm for IAM policy changes | CloudWatch alarm + metric filter | Automated |
| 4.8 | Alarm for S3 bucket policy changes | CloudWatch alarm + metric filter | Automated |
| 4.12 | Alarm for security group changes | CloudWatch alarm + metric filter | Automated |

## 5. Networking

| CIS Control | Description | Implementation | Status |
|---|---|---|---|
| 5.1 | No network ACLs allow unrestricted access | Config rule: `restricted-ssh`, `restricted-rdp` | Automated |
| 5.2 | Default security group restricts all traffic | Config rule + Terraform | Automated |
| 5.3 | VPC peering routing not overly permissive | Manual review required | Manual |
| 5.4 | Routing tables for VPC peering reviewed | Manual review required | Manual |

## Compliance Score Target

| Standard | Target Score | Current Implementation |
|---|---|---|
| CIS v1.2.0 | 90%+ | Security Hub standard enabled |
| CIS v3.0.0 | 85%+ | Security Hub standard enabled |
| AWS Foundational | 95%+ | Security Hub standard enabled |
| NIST 800-53 | 80%+ | Security Hub standard enabled |
