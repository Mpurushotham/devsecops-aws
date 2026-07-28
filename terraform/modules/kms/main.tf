variable "environment" {
  description = "Deployment environment name, used as a prefix for all resources"
  type        = string
}

variable "service_name" {
  description = "Service qualifier used in the key description and alias"
  type        = string
  default     = "devsecops"
}

variable "deletion_window" {
  description = "Days the key stays pending deletion before being destroyed"
  type        = number
  default     = 30

  validation {
    condition     = var.deletion_window >= 7 && var.deletion_window <= 30
    error_message = "AWS only accepts a deletion window between 7 and 30 days."
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_kms_key" "main" {
  description             = "${var.environment}-${var.service_name}-key"
  deletion_window_in_days = var.deletion_window
  enable_key_rotation     = true
  multi_region            = false

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "Enable IAM Root Permissions"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "Allow CloudWatch Logs"
        Effect    = "Allow"
        Principal = { Service = "logs.${data.aws_region.current.name}.amazonaws.com" }
        Action    = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource  = "*"
      },
      {
        Sid       = "Allow S3 Service"
        Effect    = "Allow"
        Principal = { Service = "s3.amazonaws.com" }
        Action    = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource  = "*"
      },
      # CloudTrail encrypts each log file with a data key from this key. Without
      # this statement the trail fails to start and reports KMS access denied.
      {
        Sid       = "Allow CloudTrail"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = ["kms:GenerateDataKey*", "kms:DescribeKey", "kms:Decrypt"]
        Resource  = "*"
        Condition = {
          StringLike = {
            "kms:EncryptionContext:aws:cloudtrail:arn" = "arn:aws:cloudtrail:*:${data.aws_caller_identity.current.account_id}:trail/*"
          }
        }
      },
      {
        Sid       = "Allow AWS Config"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = ["kms:GenerateDataKey*", "kms:DescribeKey", "kms:Decrypt"]
        Resource  = "*"
      },
      # Used by the VPC flow log and WAF log delivery paths.
      {
        Sid       = "Allow Log Delivery"
        Effect    = "Allow"
        Principal = { Service = "delivery.logs.amazonaws.com" }
        Action    = ["kms:GenerateDataKey*", "kms:DescribeKey", "kms:Decrypt"]
        Resource  = "*"
      },
      # EKS envelope encryption of Kubernetes secrets and EBS volume encryption
      # both go through the autoscaling and EKS service principals.
      {
        Sid       = "Allow EKS"
        Effect    = "Allow"
        Principal = { Service = "eks.amazonaws.com" }
        Action    = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey", "kms:CreateGrant"]
        Resource  = "*"
      }
    ]
  })

  tags = { Environment = var.environment, Service = var.service_name }
}

resource "aws_kms_alias" "main" {
  name          = "alias/${var.environment}-${var.service_name}"
  target_key_id = aws_kms_key.main.key_id
}

output "key_id" {
  description = "ID of the customer-managed key"
  value       = aws_kms_key.main.key_id
}

output "key_arn" {
  description = "ARN of the customer-managed key"
  value       = aws_kms_key.main.arn
}

output "key_alias" {
  description = "Alias name of the customer-managed key"
  value       = aws_kms_alias.main.name
}
