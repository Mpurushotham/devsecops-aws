variable "environment" {
  description = "Deployment environment name, applied as a tag"
  type        = string
}

variable "bucket_name" {
  description = "Globally unique bucket name"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key ARN used for default SSE-KMS encryption"
  type        = string
}

variable "versioning_enabled" {
  description = "Enable object versioning"
  type        = bool
  default     = true
}

variable "lifecycle_days" {
  description = "Age in days at which current objects transition to Glacier"
  type        = number
  default     = 90
}

variable "access_log_bucket_id" {
  description = <<-EOT
    Bucket that receives S3 server access logs for this bucket. Leave empty for
    the access-log bucket itself: a bucket that logs to itself creates a
    feedback loop where each log write generates another log record.
  EOT
  type        = string
  default     = ""
}

variable "log_delivery_services" {
  description = <<-EOT
    AWS log producers allowed to write into this bucket. Each entry adds the
    bucket policy statements that service requires before it will deliver.
    Supported: cloudtrail, config, alb.
  EOT
  type        = set(string)
  default     = []

  validation {
    condition     = alltrue([for s in var.log_delivery_services : contains(["cloudtrail", "config", "alb"], s)])
    error_message = "log_delivery_services entries must be one of: cloudtrail, config, alb."
  }
}

variable "is_access_log_bucket" {
  description = "Marks this bucket as the account's S3 access-log target, adding the log delivery service to its bucket policy"
  type        = bool
  default     = false
}

variable "object_lock_enabled" {
  description = "Enable S3 Object Lock in governance mode. Must be set at creation time and cannot be toggled later."
  type        = bool
  default     = false
}

variable "object_lock_retention_days" {
  description = "Governance-mode retention applied to new objects when object_lock_enabled is true"
  type        = number
  default     = 30
}

resource "aws_s3_bucket" "main" {
  bucket              = var.bucket_name
  force_destroy       = false
  object_lock_enabled = var.object_lock_enabled
  tags                = { Environment = var.environment }
}

resource "aws_s3_bucket_object_lock_configuration" "main" {
  count  = var.object_lock_enabled ? 1 : 0
  bucket = aws_s3_bucket.main.id

  rule {
    default_retention {
      mode = "GOVERNANCE"
      days = var.object_lock_retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.main]
}

resource "aws_s3_bucket_versioning" "main" {
  bucket = aws_s3_bucket.main.id
  versioning_configuration {
    status = var.versioning_enabled ? "Enabled" : "Disabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "main" {
  bucket = aws_s3_bucket.main.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "main" {
  bucket                  = aws_s3_bucket.main.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "main" {
  bucket = aws_s3_bucket.main.id

  rule {
    id     = "transition-to-ia"
    status = "Enabled"

    # An empty filter scopes the rule to every object. Omitting filter and
    # prefix entirely is accepted today but the provider warns it will become
    # an error.
    filter {}

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = var.lifecycle_days
      storage_class = "GLACIER"
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }

  # Multipart uploads that never complete are invisible in the console but keep
  # billing for storage until explicitly aborted.
  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_logging" "main" {
  count  = var.access_log_bucket_id == "" ? 0 : 1
  bucket = aws_s3_bucket.main.id

  target_bucket = var.access_log_bucket_id
  target_prefix = "s3-access-logs/${var.bucket_name}/"
}

data "aws_caller_identity" "current" {}

# The regional account AWS uses to deliver ALB access logs. Some regions use a
# named account principal rather than the delivery.logs service principal.
data "aws_elb_service_account" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

# Composed as a policy document rather than a jsonencode of conditional lists:
# the statements have different shapes, and Terraform cannot unify the types of
# a conditional whose branches are object lists with differing attributes.
data "aws_iam_policy_document" "bucket" {
  statement {
    sid     = "DenyNonTLS"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.main.arn,
      "${aws_s3_bucket.main.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid     = "DenyOutdatedTLS"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.main.arn,
      "${aws_s3_bucket.main.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "NumericLessThan"
      variable = "s3:TlsVersion"
      values   = ["1.2"]
    }
  }

  # Denies only an explicit request for something other than SSE-KMS. A plain
  # PUT with no header still succeeds and picks up the bucket default; denying
  # those would also block AWS log delivery, which never sets the header.
  statement {
    sid       = "DenyIncorrectEncryptionHeader"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.main.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }

    condition {
      test     = "Null"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["false"]
    }
  }

  # Only granted on the access-log bucket itself, which is the one bucket that
  # does not forward its own logs anywhere.
  dynamic "statement" {
    for_each = var.is_access_log_bucket ? [1] : []

    content {
      sid       = "AllowS3ServerAccessLogDelivery"
      effect    = "Allow"
      actions   = ["s3:PutObject"]
      resources = ["${aws_s3_bucket.main.arn}/*"]

      principals {
        type        = "Service"
        identifiers = ["logging.s3.amazonaws.com"]
      }

      condition {
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [local.account_id]
      }
    }
  }

  # CloudTrail refuses to create a trail whose destination bucket policy does
  # not already grant these actions, so they must exist before the trail does.
  dynamic "statement" {
    for_each = contains(var.log_delivery_services, "cloudtrail") ? [1] : []

    content {
      sid       = "AWSCloudTrailAclCheck"
      effect    = "Allow"
      actions   = ["s3:GetBucketAcl"]
      resources = [aws_s3_bucket.main.arn]

      principals {
        type        = "Service"
        identifiers = ["cloudtrail.amazonaws.com"]
      }
    }
  }

  dynamic "statement" {
    for_each = contains(var.log_delivery_services, "cloudtrail") ? [1] : []

    content {
      sid       = "AWSCloudTrailWrite"
      effect    = "Allow"
      actions   = ["s3:PutObject"]
      resources = ["${aws_s3_bucket.main.arn}/AWSLogs/${local.account_id}/*"]

      principals {
        type        = "Service"
        identifiers = ["cloudtrail.amazonaws.com"]
      }

      condition {
        test     = "StringEquals"
        variable = "s3:x-amz-acl"
        values   = ["bucket-owner-full-control"]
      }
    }
  }

  dynamic "statement" {
    for_each = contains(var.log_delivery_services, "config") ? [1] : []

    content {
      sid       = "AWSConfigAclCheck"
      effect    = "Allow"
      actions   = ["s3:GetBucketAcl", "s3:ListBucket"]
      resources = [aws_s3_bucket.main.arn]

      principals {
        type        = "Service"
        identifiers = ["config.amazonaws.com"]
      }
    }
  }

  dynamic "statement" {
    for_each = contains(var.log_delivery_services, "config") ? [1] : []

    content {
      sid       = "AWSConfigWrite"
      effect    = "Allow"
      actions   = ["s3:PutObject"]
      resources = ["${aws_s3_bucket.main.arn}/AWSLogs/${local.account_id}/Config/*"]

      principals {
        type        = "Service"
        identifiers = ["config.amazonaws.com"]
      }

      condition {
        test     = "StringEquals"
        variable = "s3:x-amz-acl"
        values   = ["bucket-owner-full-control"]
      }
    }
  }

  dynamic "statement" {
    for_each = contains(var.log_delivery_services, "alb") ? [1] : []

    content {
      sid       = "AWSALBAccessLogDelivery"
      effect    = "Allow"
      actions   = ["s3:PutObject"]
      resources = ["${aws_s3_bucket.main.arn}/alb/AWSLogs/${local.account_id}/*"]

      principals {
        type        = "AWS"
        identifiers = [data.aws_elb_service_account.current.arn]
      }
    }
  }

  dynamic "statement" {
    for_each = contains(var.log_delivery_services, "alb") ? [1] : []

    content {
      sid       = "AWSLogDeliveryWrite"
      effect    = "Allow"
      actions   = ["s3:PutObject"]
      resources = ["${aws_s3_bucket.main.arn}/alb/AWSLogs/${local.account_id}/*"]

      principals {
        type        = "Service"
        identifiers = ["delivery.logs.amazonaws.com"]
      }

      condition {
        test     = "StringEquals"
        variable = "s3:x-amz-acl"
        values   = ["bucket-owner-full-control"]
      }
    }
  }

  dynamic "statement" {
    for_each = contains(var.log_delivery_services, "alb") ? [1] : []

    content {
      sid       = "AWSLogDeliveryAclCheck"
      effect    = "Allow"
      actions   = ["s3:GetBucketAcl"]
      resources = [aws_s3_bucket.main.arn]

      principals {
        type        = "Service"
        identifiers = ["delivery.logs.amazonaws.com"]
      }
    }
  }
}

resource "aws_s3_bucket_policy" "main" {
  bucket = aws_s3_bucket.main.id
  policy = data.aws_iam_policy_document.bucket.json

  depends_on = [aws_s3_bucket_public_access_block.main]
}

output "bucket_id" {
  description = "Name of the bucket"
  value       = aws_s3_bucket.main.id
}

output "bucket_arn" {
  description = "ARN of the bucket"
  value       = aws_s3_bucket.main.arn
}

output "bucket_domain_name" {
  description = "Regional domain name of the bucket"
  value       = aws_s3_bucket.main.bucket_regional_domain_name
}
