variable "environment" {}
variable "service_name" { default = "devsecops" }
variable "deletion_window" { default = 30 }

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
        Sid    = "Enable IAM Root Permissions"
        Effect = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "Allow CloudWatch Logs"
        Effect = "Allow"
        Principal = { Service = "logs.${data.aws_region.current.name}.amazonaws.com" }
        Action   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource = "*"
      },
      {
        Sid    = "Allow S3 Service"
        Effect = "Allow"
        Principal = { Service = "s3.amazonaws.com" }
        Action   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource = "*"
      }
    ]
  })

  tags = { Environment = var.environment, Service = var.service_name }
}

resource "aws_kms_alias" "main" {
  name          = "alias/${var.environment}-${var.service_name}"
  target_key_id = aws_kms_key.main.key_id
}

output "key_id"  { value = aws_kms_key.main.key_id }
output "key_arn" { value = aws_kms_key.main.arn }
