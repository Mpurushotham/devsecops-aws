variable "root_email_prefix" { default = "aws" }
variable "org_domain"        {}

resource "aws_organizations_organization" "main" {
  aws_service_access_principals = [
    "cloudtrail.amazonaws.com",
    "config.amazonaws.com",
    "securityhub.amazonaws.com",
    "guardduty.amazonaws.com",
    "access-analyzer.amazonaws.com",
    "sso.amazonaws.com",
    "ram.amazonaws.com",
  ]

  feature_set          = "ALL"
  enabled_policy_types = ["SERVICE_CONTROL_POLICY", "TAG_POLICY"]
}

# --- Organizational Units ---
resource "aws_organizations_organizational_unit" "security" {
  name      = "Security"
  parent_id = aws_organizations_organization.main.roots[0].id
}

resource "aws_organizations_organizational_unit" "workloads" {
  name      = "Workloads"
  parent_id = aws_organizations_organization.main.roots[0].id
}

resource "aws_organizations_organizational_unit" "dev" {
  name      = "Dev"
  parent_id = aws_organizations_organizational_unit.workloads.id
}

resource "aws_organizations_organizational_unit" "staging" {
  name      = "Staging"
  parent_id = aws_organizations_organizational_unit.workloads.id
}

resource "aws_organizations_organizational_unit" "prod" {
  name      = "Prod"
  parent_id = aws_organizations_organizational_unit.workloads.id
}

resource "aws_organizations_organizational_unit" "sandbox" {
  name      = "Sandbox"
  parent_id = aws_organizations_organization.main.roots[0].id
}

# --- SCP: Deny Leaving Org ---
resource "aws_organizations_policy" "deny_leave_org" {
  name        = "deny-leaving-organization"
  description = "Prevent accounts from leaving the organization"
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "DenyLeaveOrganization"
      Effect   = "Deny"
      Action   = "organizations:LeaveOrganization"
      Resource = "*"
    }]
  })
}

resource "aws_organizations_policy_attachment" "deny_leave_org_root" {
  policy_id = aws_organizations_policy.deny_leave_org.id
  target_id = aws_organizations_organization.main.roots[0].id
}

# --- SCP: Deny Root User Actions ---
resource "aws_organizations_policy" "deny_root_actions" {
  name        = "deny-root-user-actions"
  description = "Prevent root user from performing actions"
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "DenyRootUserAccess"
      Effect   = "Deny"
      Action   = "*"
      Resource = "*"
      Condition = {
        StringEquals = { "aws:PrincipalType" = "Root" }
      }
    }]
  })
}

resource "aws_organizations_policy_attachment" "deny_root_workloads" {
  policy_id = aws_organizations_policy.deny_root_actions.id
  target_id = aws_organizations_organizational_unit.workloads.id
}

# --- SCP: Allowed Regions ---
resource "aws_organizations_policy" "allowed_regions" {
  name        = "allowed-aws-regions"
  description = "Restrict resource creation to approved AWS regions"
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "DenyUnapprovedRegions"
      Effect = "Deny"
      NotAction = [
        "iam:*", "organizations:*", "route53:*", "budgets:*",
        "waf:*", "cloudfront:*", "sts:*", "support:*"
      ]
      Resource = "*"
      Condition = {
        StringNotIn = {
          "aws:RequestedRegion" = ["us-east-1", "us-west-2", "eu-west-1"]
        }
      }
    }]
  })
}

resource "aws_organizations_policy_attachment" "allowed_regions_prod" {
  policy_id = aws_organizations_policy.allowed_regions.id
  target_id = aws_organizations_organizational_unit.prod.id
}

# --- SCP: Deny Disabling Security Services ---
resource "aws_organizations_policy" "deny_disable_security" {
  name        = "deny-disabling-security-services"
  description = "Prevent disabling core security services"
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyDisableGuardDuty"
        Effect = "Deny"
        Action = [
          "guardduty:DeleteDetector", "guardduty:DisassociateFromMasterAccount",
          "guardduty:StopMonitoringMembers", "guardduty:DeleteMembers"
        ]
        Resource = "*"
      },
      {
        Sid    = "DenyDisableSecurityHub"
        Effect = "Deny"
        Action = [
          "securityhub:DeleteHub", "securityhub:DisableSecurityHub",
          "securityhub:DisassociateFromMasterAccount"
        ]
        Resource = "*"
      },
      {
        Sid    = "DenyDisableCloudTrail"
        Effect = "Deny"
        Action = ["cloudtrail:StopLogging", "cloudtrail:DeleteTrail", "cloudtrail:UpdateTrail"]
        Resource = "*"
      },
      {
        Sid    = "DenyDisableConfig"
        Effect = "Deny"
        Action = ["config:DeleteConfigurationRecorder", "config:StopConfigurationRecorder", "config:DeleteDeliveryChannel"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_organizations_policy_attachment" "deny_disable_security_root" {
  policy_id = aws_organizations_policy.deny_disable_security.id
  target_id = aws_organizations_organization.main.roots[0].id
}

# --- SCP: Require Encryption ---
resource "aws_organizations_policy" "require_encryption" {
  name        = "require-encryption"
  description = "Require encryption for S3, EBS, RDS"
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyUnencryptedS3"
        Effect = "Deny"
        Action = "s3:PutObject"
        Resource = "*"
        Condition = {
          StringNotEquals = { "s3:x-amz-server-side-encryption" = ["aws:kms", "AES256"] }
          Null            = { "s3:x-amz-server-side-encryption" = "false" }
        }
      },
      {
        Sid    = "DenyUnencryptedEBS"
        Effect = "Deny"
        Action = "ec2:RunInstances"
        Resource = "arn:aws:ec2:*:*:volume/*"
        Condition = {
          Bool = { "ec2:Encrypted" = "false" }
        }
      },
      {
        Sid    = "DenyUnencryptedRDS"
        Effect = "Deny"
        Action = "rds:CreateDBInstance"
        Resource = "*"
        Condition = {
          Bool = { "rds:StorageEncrypted" = "false" }
        }
      }
    ]
  })
}

resource "aws_organizations_policy_attachment" "require_encryption_prod" {
  policy_id = aws_organizations_policy.require_encryption.id
  target_id = aws_organizations_organizational_unit.prod.id
}

output "org_id"      { value = aws_organizations_organization.main.id }
output "root_id"     { value = aws_organizations_organization.main.roots[0].id }
output "prod_ou_id"  { value = aws_organizations_organizational_unit.prod.id }
