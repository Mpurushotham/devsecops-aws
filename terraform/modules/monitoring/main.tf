variable "environment" {
  description = "Deployment environment name, used as a prefix for all resources"
  type        = string
}

variable "sns_alarm_arn" {
  description = "SNS topic ARN notified by the CIS alarms. Alarm actions are omitted when empty."
  type        = string
  default     = ""
}

variable "eks_cluster_name" {
  description = "EKS cluster name surfaced on the dashboard"
  type        = string
  default     = ""
}

variable "ecs_cluster_name" {
  description = "ECS cluster name surfaced on the dashboard"
  type        = string
  default     = ""
}

variable "aws_region" {
  description = "Region used for dashboard widget queries"
  type        = string
}

variable "cloudtrail_log_group_name" {
  description = "CloudWatch log group receiving CloudTrail events, the source for the CIS metric filters"
  type        = string
}

# Alarm actions must be an empty list rather than [""] when no topic is wired up,
# otherwise CloudWatch rejects the malformed ARN.
locals {
  alarm_actions = var.sns_alarm_arn == "" ? [] : [var.sns_alarm_arn]
}

# --- CloudWatch Dashboard ---
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.environment}-devsecops-overview"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title = "ECS CPU/Memory Utilization"
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", var.ecs_cluster_name],
            ["AWS/ECS", "MemoryUtilization", "ClusterName", var.ecs_cluster_name]
          ]
          region = var.aws_region
          period = 300
          stat   = "Average"
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title = "Security Hub - Critical Findings"
          metrics = [
            ["AWS/SecurityHub", "TotalFindings", { stat = "Sum" }]
          ]
          region = var.aws_region
          period = 3600
          view   = "singleValue"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title = "GuardDuty Findings"
          metrics = [
            ["AWS/GuardDuty", "FindingCount"]
          ]
          region = var.aws_region
          period = 3600
          stat   = "Sum"
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          title = "EKS Node CPU/Memory Utilization"
          metrics = [
            ["ContainerInsights", "node_cpu_utilization", "ClusterName", var.eks_cluster_name],
            ["ContainerInsights", "node_memory_utilization", "ClusterName", var.eks_cluster_name]
          ]
          region = var.aws_region
          period = 300
          stat   = "Average"
          view   = "timeSeries"
        }
      },
      {
        type   = "log"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "CloudTrail - Root Logins"
          query  = "SOURCE '${var.cloudtrail_log_group_name}' | filter userIdentity.type='Root' | stats count(*) by eventName"
          region = var.aws_region
          view   = "table"
        }
      }
    ]
  })
}

# --- CloudWatch Alarms ---

resource "aws_cloudwatch_metric_alarm" "root_login" {
  alarm_name          = "${var.environment}-root-account-login"
  alarm_description   = "Alert on root account login"
  metric_name         = "RootAccountUsage"
  namespace           = "CloudTrailMetrics"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "unauthorized_api" {
  alarm_name          = "${var.environment}-unauthorized-api-calls"
  alarm_description   = "Alert on unauthorized API calls"
  metric_name         = "UnauthorizedAttemptCount"
  namespace           = "CloudTrailMetrics"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "console_without_mfa" {
  alarm_name          = "${var.environment}-console-signin-no-mfa"
  alarm_description   = "Alert on console sign-in without MFA"
  metric_name         = "ConsoleSignInWithoutMFA"
  namespace           = "CloudTrailMetrics"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "iam_policy_change" {
  alarm_name          = "${var.environment}-iam-policy-changes"
  alarm_description   = "Alert on IAM policy changes"
  metric_name         = "IAMPolicyChanges"
  namespace           = "CloudTrailMetrics"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "sg_changes" {
  alarm_name          = "${var.environment}-security-group-changes"
  alarm_description   = "Alert on security group configuration changes"
  metric_name         = "SecurityGroupChanges"
  namespace           = "CloudTrailMetrics"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
}

# --- CloudWatch Log Metric Filters (required for alarms above) ---

resource "aws_cloudwatch_log_metric_filter" "root_login" {
  name           = "${var.environment}-root-login-filter"
  log_group_name = var.cloudtrail_log_group_name
  pattern        = "{ $.userIdentity.type = \"Root\" && $.userIdentity.invokedBy NOT EXISTS && $.eventType != \"AwsServiceEvent\" }"

  metric_transformation {
    name      = "RootAccountUsage"
    namespace = "CloudTrailMetrics"
    value     = "1"
  }
}

resource "aws_cloudwatch_log_metric_filter" "unauthorized_api" {
  name           = "${var.environment}-unauthorized-api-filter"
  log_group_name = var.cloudtrail_log_group_name
  pattern        = "{ ($.errorCode = \"*UnauthorizedAccess*\") || ($.errorCode = \"AccessDenied*\") }"

  metric_transformation {
    name      = "UnauthorizedAttemptCount"
    namespace = "CloudTrailMetrics"
    value     = "1"
  }
}

resource "aws_cloudwatch_log_metric_filter" "console_without_mfa" {
  name           = "${var.environment}-console-no-mfa-filter"
  log_group_name = var.cloudtrail_log_group_name
  pattern        = "{ $.eventName = \"ConsoleLogin\" && $.additionalEventData.MFAUsed = \"No\" }"

  metric_transformation {
    name      = "ConsoleSignInWithoutMFA"
    namespace = "CloudTrailMetrics"
    value     = "1"
  }
}

resource "aws_cloudwatch_log_metric_filter" "iam_policy_change" {
  name           = "${var.environment}-iam-policy-change-filter"
  log_group_name = var.cloudtrail_log_group_name
  pattern        = "{ ($.eventName = DeleteGroupPolicy) || ($.eventName = DeleteRolePolicy) || ($.eventName = DeleteUserPolicy) || ($.eventName = PutGroupPolicy) || ($.eventName = PutRolePolicy) || ($.eventName = PutUserPolicy) || ($.eventName = CreatePolicy) || ($.eventName = DeletePolicy) || ($.eventName = CreatePolicyVersion) || ($.eventName = DeletePolicyVersion) || ($.eventName = SetDefaultPolicyVersion) || ($.eventName = AttachRolePolicy) || ($.eventName = DetachRolePolicy) || ($.eventName = AttachUserPolicy) || ($.eventName = DetachUserPolicy) || ($.eventName = AttachGroupPolicy) || ($.eventName = DetachGroupPolicy) }"

  metric_transformation {
    name      = "IAMPolicyChanges"
    namespace = "CloudTrailMetrics"
    value     = "1"
  }
}

resource "aws_cloudwatch_log_metric_filter" "sg_changes" {
  name           = "${var.environment}-sg-change-filter"
  log_group_name = var.cloudtrail_log_group_name
  pattern        = "{ ($.eventName = AuthorizeSecurityGroupIngress) || ($.eventName = AuthorizeSecurityGroupEgress) || ($.eventName = RevokeSecurityGroupIngress) || ($.eventName = RevokeSecurityGroupEgress) || ($.eventName = CreateSecurityGroup) || ($.eventName = DeleteSecurityGroup) }"

  metric_transformation {
    name      = "SecurityGroupChanges"
    namespace = "CloudTrailMetrics"
    value     = "1"
  }
}

output "dashboard_arn" { value = aws_cloudwatch_dashboard.main.dashboard_arn }
