variable "environment" {
  description = "Deployment environment name, used as a prefix for all resources"
  type        = string
}

variable "rate_limit" {
  description = "Requests per 5-minute window from a single IP before blocking"
  type        = number
  default     = 2000
}

variable "kms_key_arn" {
  description = "KMS key ARN used to encrypt the WAF log group"
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch retention for WAF logs"
  type        = number
  default     = 90
}

resource "aws_wafv2_web_acl" "main" {
  name  = "${var.environment}-devsecops-waf"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "CommonRuleSetMetric"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "KnownBadInputsMetric"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "RateLimitRule"
    priority = 3
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = var.rate_limit
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimitMetric"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.environment}-devsecops-waf"
    sampled_requests_enabled   = true
  }

  tags = { Environment = var.environment }
}

# --- Logging ---
# Without this the WAF blocks traffic but leaves no record of what it blocked,
# which makes tuning false positives guesswork.

# The log group name must start with aws-waf-logs- or PutLoggingConfiguration
# is rejected.
resource "aws_cloudwatch_log_group" "waf" {
  name              = "aws-waf-logs-${var.environment}-devsecops"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
}

resource "aws_wafv2_web_acl_logging_configuration" "main" {
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]
  resource_arn            = aws_wafv2_web_acl.main.arn

  redacted_fields {
    single_header {
      name = "authorization"
    }
  }

  redacted_fields {
    single_header {
      name = "cookie"
    }
  }
}

output "web_acl_arn" {
  description = "ARN of the WAF web ACL, to associate with an ALB or API Gateway stage"
  value       = aws_wafv2_web_acl.main.arn
}

output "web_acl_id" {
  description = "ID of the WAF web ACL"
  value       = aws_wafv2_web_acl.main.id
}

output "log_group_name" {
  description = "CloudWatch log group receiving WAF logs"
  value       = aws_cloudwatch_log_group.waf.name
}
