variable "environment" {
  description = "Deployment environment name, used as a prefix for all resources"
  type        = string
}

variable "s3_bucket_id" {
  description = "Bucket receiving Config configuration snapshots and history"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key ARN used to encrypt Config deliveries to S3"
  type        = string
}

resource "aws_iam_role" "config" {
  name = "${var.environment}-aws-config-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "config.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "config" {
  role       = aws_iam_role.config.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

resource "aws_config_configuration_recorder" "main" {
  name     = "${var.environment}-config-recorder"
  role_arn = aws_iam_role.config.arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

resource "aws_config_delivery_channel" "main" {
  name           = "${var.environment}-config-delivery"
  s3_bucket_name = var.s3_bucket_id
  s3_key_prefix  = "config"
  # The key was passed in but never applied, so snapshots were landing under
  # the bucket default rather than the key this module was handed.
  s3_kms_key_arn = var.kms_key_arn

  snapshot_delivery_properties {
    delivery_frequency = "Six_Hours"
  }

  depends_on = [aws_config_configuration_recorder.main]
}

resource "aws_config_configuration_recorder_status" "main" {
  name       = aws_config_configuration_recorder.main.name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.main]
}

# --- Managed Config Rules ---

resource "aws_config_config_rule" "root_mfa" {
  name        = "root-account-mfa-enabled"
  description = "Checks if MFA is enabled for root account"

  source {
    owner             = "AWS"
    source_identifier = "ROOT_ACCOUNT_MFA_ENABLED"
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

resource "aws_config_config_rule" "iam_password_policy" {
  name        = "iam-password-policy"
  description = "Checks IAM password policy meets requirements"

  source {
    owner             = "AWS"
    source_identifier = "IAM_PASSWORD_POLICY"
  }

  input_parameters = jsonencode({
    RequireUppercaseCharacters = "true"
    RequireLowercaseCharacters = "true"
    RequireSymbols             = "true"
    RequireNumbers             = "true"
    MinimumPasswordLength      = "14"
    PasswordReusePrevention    = "24"
    MaxPasswordAge             = "90"
  })

  depends_on = [aws_config_configuration_recorder_status.main]
}

resource "aws_config_config_rule" "s3_public_read" {
  name        = "s3-bucket-public-read-prohibited"
  description = "Checks S3 buckets do not allow public read"

  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_PUBLIC_READ_PROHIBITED"
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

resource "aws_config_config_rule" "s3_public_write" {
  name        = "s3-bucket-public-write-prohibited"
  description = "Checks S3 buckets do not allow public write"

  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_PUBLIC_WRITE_PROHIBITED"
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

resource "aws_config_config_rule" "s3_encryption" {
  name        = "s3-bucket-server-side-encryption-enabled"
  description = "Checks S3 buckets have server-side encryption"

  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_SERVER_SIDE_ENCRYPTION_ENABLED"
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

resource "aws_config_config_rule" "encrypted_volumes" {
  name        = "encrypted-volumes"
  description = "Checks EBS volumes are encrypted"

  source {
    owner             = "AWS"
    source_identifier = "ENCRYPTED_VOLUMES"
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

resource "aws_config_config_rule" "rds_encryption" {
  name        = "rds-storage-encrypted"
  description = "Checks RDS instances are encrypted at rest"

  source {
    owner             = "AWS"
    source_identifier = "RDS_STORAGE_ENCRYPTED"
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

resource "aws_config_config_rule" "cloudtrail_enabled" {
  name        = "cloud-trail-enabled"
  description = "Checks CloudTrail is enabled"

  source {
    owner             = "AWS"
    source_identifier = "CLOUD_TRAIL_ENABLED"
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

resource "aws_config_config_rule" "vpc_flow_logs" {
  name        = "vpc-flow-logs-enabled"
  description = "Checks VPC flow logs are enabled"

  source {
    owner             = "AWS"
    source_identifier = "VPC_FLOW_LOGS_ENABLED"
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

resource "aws_config_config_rule" "iam_no_root_access_key" {
  name        = "iam-root-access-key-check"
  description = "Checks root account has no access keys"

  source {
    owner             = "AWS"
    source_identifier = "IAM_ROOT_ACCESS_KEY_CHECK"
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

resource "aws_config_config_rule" "sg_no_unrestricted_ssh" {
  name        = "restricted-ssh"
  description = "Checks security groups restrict SSH from 0.0.0.0/0"

  source {
    owner             = "AWS"
    source_identifier = "INCOMING_SSH_DISABLED"
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

resource "aws_config_config_rule" "sg_no_unrestricted_rdp" {
  name        = "restricted-rdp"
  description = "Checks security groups restrict RDP from 0.0.0.0/0"

  source {
    owner             = "AWS"
    source_identifier = "RESTRICTED_INCOMING_TRAFFIC"
  }

  input_parameters = jsonencode({ blockedPort1 = "3389" })

  depends_on = [aws_config_configuration_recorder_status.main]
}

resource "aws_config_config_rule" "eks_secrets_encrypted" {
  name        = "eks-secrets-encrypted"
  description = "Checks EKS clusters encrypt Kubernetes secrets"

  source {
    owner             = "AWS"
    source_identifier = "EKS_SECRETS_ENCRYPTED"
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

# Auto-remediation for S3 public access
resource "aws_config_remediation_configuration" "s3_public_read" {
  config_rule_name = aws_config_config_rule.s3_public_read.name
  target_type      = "SSM_DOCUMENT"
  target_id        = "AWS-DisableS3BucketPublicReadWrite"
  automatic        = true

  maximum_automatic_attempts = 3
  retry_attempt_seconds      = 60

  parameter {
    name         = "AutomationAssumeRole"
    static_value = aws_iam_role.config_remediation.arn
  }
  parameter {
    name           = "S3BucketName"
    resource_value = "RESOURCE_ID"
  }
}

data "aws_caller_identity" "current" {}

resource "aws_iam_role" "config_remediation" {
  name = "${var.environment}-config-remediation-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ssm.amazonaws.com" }
      # Confused-deputy guard: without these, any SSM automation in any account
      # that can reach this role could assume it.
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })
}

# This role previously carried AdministratorAccess. It is assumable by the SSM
# service to run one automation document, so full admin made the remediation
# path a privilege escalation route: anything able to invoke SSM automation
# inherited unrestricted access to the account.
#
# Scoped to exactly what AWS-DisableS3BucketPublicReadWrite calls.
resource "aws_iam_role_policy" "config_remediation" {
  # checkov:skip=CKV_AWS_355: the remediation acts on whichever bucket the
  # Config finding names, which is not knowable when the policy is written.
  # checkov:skip=CKV_AWS_289: the permissive-sounding actions here are the
  # minimum AWS-DisableS3BucketPublicReadWrite needs to restore a public access
  # block. This replaced an AdministratorAccess attachment, so the wildcard
  # resource on seven scoped S3 actions is a large reduction, not an expansion.
  name = "${var.environment}-config-remediation-policy"
  role = aws_iam_role.config_remediation.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RestoreS3PublicAccessBlock"
        Effect = "Allow"
        Action = [
          "s3:GetBucketPublicAccessBlock",
          "s3:PutBucketPublicAccessBlock",
          "s3:GetBucketAcl",
          "s3:PutBucketAcl",
          "s3:GetBucketPolicyStatus",
          "s3:GetBucketLocation",
          "s3:ListAllMyBuckets",
        ]
        Resource = "*"
      },
      {
        Sid      = "ReportRemediationOutcome"
        Effect   = "Allow"
        Action   = ["config:PutEvaluations", "ssm:GetAutomationExecution"]
        Resource = "*"
      }
    ]
  })
}

output "recorder_name" {
  description = "Name of the Config configuration recorder"
  value       = aws_config_configuration_recorder.main.name
}

output "remediation_role_arn" {
  description = "Role SSM assumes to remediate findings"
  value       = aws_iam_role.config_remediation.arn
}
