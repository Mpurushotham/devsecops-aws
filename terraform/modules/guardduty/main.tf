variable "environment" {
  description = "Deployment environment name, used as a prefix for all resources"
  type        = string
}

variable "finding_publishing_frequency" {
  description = "How often findings are exported to EventBridge and Security Hub"
  type        = string
  default     = "FIFTEEN_MINUTES"

  validation {
    condition     = contains(["FIFTEEN_MINUTES", "ONE_HOUR", "SIX_HOURS"], var.finding_publishing_frequency)
    error_message = "Must be one of FIFTEEN_MINUTES, ONE_HOUR, SIX_HOURS."
  }
}

resource "aws_guardduty_detector" "main" {
  enable                       = true
  finding_publishing_frequency = var.finding_publishing_frequency

  tags = { Environment = var.environment }

  datasources {
    s3_logs { enable = true }
    kubernetes {
      audit_logs { enable = true }
    }
    malware_protection {
      scan_ec2_instance_with_findings {
        ebs_volumes { enable = true }
      }
    }
  }
}

# Surfaces high-severity findings as a saved view. The action is NOOP rather
# than ARCHIVE: archiving would suppress exactly the findings that matter and
# stop them reaching Security Hub and the alerting path.
resource "aws_guardduty_filter" "high_severity" {
  name        = "${var.environment}-high-severity-findings"
  action      = "NOOP"
  detector_id = aws_guardduty_detector.main.id
  rank        = 1

  finding_criteria {
    criterion {
      field                 = "severity"
      greater_than_or_equal = "7"
    }
  }

  tags = { Environment = var.environment }
}

output "detector_id" {
  description = "GuardDuty detector ID"
  value       = aws_guardduty_detector.main.id
}

output "detector_arn" {
  description = "GuardDuty detector ARN"
  value       = aws_guardduty_detector.main.arn
}
