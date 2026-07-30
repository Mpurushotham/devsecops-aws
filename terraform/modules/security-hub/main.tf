variable "environment" {
  description = "Deployment environment name, used as a prefix for all resources"
  type        = string
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key used to encrypt the security alert topic"
  type        = string
}

variable "enable_cis" {
  description = "Subscribe to the CIS AWS Foundations Benchmark standard"
  type        = bool
  default     = true
}

variable "enable_pci" {
  description = "Subscribe to the PCI DSS standard"
  type        = bool
  default     = false
}

variable "enable_nist" {
  description = "Subscribe to the NIST 800-53 standard"
  type        = bool
  default     = true
}

variable "enable_aws_foundational" {
  description = "Subscribe to the AWS Foundational Security Best Practices standard"
  type        = bool
  default     = true
}

resource "aws_securityhub_account" "main" {}

resource "aws_securityhub_standards_subscription" "cis" {
  count         = var.enable_cis ? 1 : 0
  standards_arn = "arn:aws:securityhub:::ruleset/cis-aws-foundations-benchmark/v/1.2.0"
  depends_on    = [aws_securityhub_account.main]
}

resource "aws_securityhub_standards_subscription" "cis_v3" {
  count         = var.enable_cis ? 1 : 0
  standards_arn = "arn:aws:securityhub:us-east-1::standards/cis-aws-foundations-benchmark/v/3.0.0"
  depends_on    = [aws_securityhub_account.main]
}

resource "aws_securityhub_standards_subscription" "aws_foundational" {
  count         = var.enable_aws_foundational ? 1 : 0
  standards_arn = "arn:aws:securityhub:us-east-1::standards/aws-foundational-security-best-practices/v/1.0.0"
  depends_on    = [aws_securityhub_account.main]
}

resource "aws_securityhub_standards_subscription" "pci" {
  count         = var.enable_pci ? 1 : 0
  standards_arn = "arn:aws:securityhub:us-east-1::standards/pci-dss/v/3.2.1"
  depends_on    = [aws_securityhub_account.main]
}

resource "aws_securityhub_standards_subscription" "nist" {
  count         = var.enable_nist ? 1 : 0
  standards_arn = "arn:aws:securityhub:us-east-1::standards/nist-800-53/v/5.0.0"
  depends_on    = [aws_securityhub_account.main]
}

resource "aws_securityhub_action_target" "slack" {
  name        = "Send to Slack"
  identifier  = "SendToSlack"
  description = "Send Security Hub findings to Slack via Lambda"
}

resource "aws_cloudwatch_event_rule" "securityhub_findings" {
  name        = "${var.environment}-securityhub-critical-findings"
  description = "Capture Critical and High Security Hub findings"

  event_pattern = jsonencode({
    source      = ["aws.securityhub"]
    detail-type = ["Security Hub Findings - Imported"]
    detail = {
      findings = {
        Severity    = { Label = ["CRITICAL", "HIGH"] }
        Workflow    = { Status = ["NEW"] }
        RecordState = ["ACTIVE"]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "securityhub_sns" {
  rule      = aws_cloudwatch_event_rule.securityhub_findings.name
  target_id = "SendToSNS"
  arn       = aws_sns_topic.security_alerts.arn
}

resource "aws_sns_topic" "security_alerts" {
  name = "${var.environment}-security-alerts"
  # The AWS-managed alias/aws/sns key cannot have its policy or rotation
  # controlled, so security findings ride on a customer-managed key instead.
  kms_master_key_id = var.kms_key_arn
}

resource "aws_sns_topic_policy" "security_alerts" {
  arn = aws_sns_topic.security_alerts.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "SNS:Publish"
      Resource  = aws_sns_topic.security_alerts.arn
    }]
  })
}

output "sns_topic_arn" { value = aws_sns_topic.security_alerts.arn }
