variable "environment" {}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# --- Permission Boundary ---
resource "aws_iam_policy" "permission_boundary" {
  name        = "${var.environment}-permission-boundary"
  description = "Permission boundary to restrict IAM role capabilities"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowRegionalServices"
        Effect   = "Allow"
        Action   = ["ec2:*", "ecs:*", "eks:*", "s3:*", "rds:*", "lambda:*", "logs:*", "cloudwatch:*", "secretsmanager:GetSecretValue", "kms:Decrypt", "kms:GenerateDataKey", "ssm:GetParameter*", "ecr:*"]
        Resource = "*"
        Condition = {
          StringEquals = { "aws:RequestedRegion" = data.aws_region.current.name }
        }
      },
      {
        Sid    = "DenyIAMEscalation"
        Effect = "Deny"
        Action = [
          "iam:CreateUser", "iam:CreateRole", "iam:DeleteRolePolicy",
          "iam:AttachRolePolicy", "iam:PutRolePolicy",
          "iam:PassRole", "organizations:*"
        ]
        Resource = "*"
      },
      {
        Sid    = "DenyRootActions"
        Effect = "Deny"
        Action = "*"
        Resource = "*"
        Condition = {
          StringEquals = { "aws:PrincipalType" = "Root" }
        }
      }
    ]
  })
}

# --- CI/CD Deploy Role ---
resource "aws_iam_role" "cicd_deploy" {
  name                 = "${var.environment}-cicd-deploy-role"
  permissions_boundary = aws_iam_policy.permission_boundary.arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com" }
      Condition = {
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:Mpurushotham/devsecops-aws:*"
        }
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "cicd_deploy" {
  name = "${var.environment}-cicd-deploy-policy"
  role = aws_iam_role.cicd_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRAccess"
        Effect = "Allow"
        Action = ["ecr:GetAuthorizationToken", "ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage", "ecr:PutImage", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload"]
        Resource = "*"
      },
      {
        Sid    = "ECSAccess"
        Effect = "Allow"
        Action = ["ecs:UpdateService", "ecs:DescribeServices", "ecs:RegisterTaskDefinition", "ecs:DescribeTaskDefinition"]
        Resource = "*"
      },
      {
        Sid    = "EKSAccess"
        Effect = "Allow"
        Action = ["eks:DescribeCluster", "eks:ListClusters"]
        Resource = "*"
      },
      {
        Sid    = "S3TerraformState"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = ["arn:aws:s3:::devsecops-aws-tfstate-${var.environment}", "arn:aws:s3:::devsecops-aws-tfstate-${var.environment}/*"]
      },
      {
        Sid    = "DynamoDBLock"
        Effect = "Allow"
        Action = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
        Resource = "arn:aws:dynamodb:*:*:table/terraform-state-lock"
      }
    ]
  })
}

# --- Developer Read-Only Role ---
resource "aws_iam_role" "developer_readonly" {
  name                 = "${var.environment}-developer-readonly"
  permissions_boundary = aws_iam_policy.permission_boundary.arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
      Condition = {
        Bool = { "aws:MultiFactorAuthPresent" = "true" }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "developer_readonly" {
  role       = aws_iam_role.developer_readonly.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# --- Security Auditor Role ---
resource "aws_iam_role" "security_auditor" {
  name = "${var.environment}-security-auditor"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
      Condition = {
        Bool = { "aws:MultiFactorAuthPresent" = "true" }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "security_auditor_readonly" {
  role       = aws_iam_role.security_auditor.name
  policy_arn = "arn:aws:iam::aws:policy/SecurityAudit"
}

resource "aws_iam_role_policy_attachment" "security_auditor_support" {
  role       = aws_iam_role.security_auditor.name
  policy_arn = "arn:aws:iam::aws:policy/AWSSupportAccess"
}

# --- Lambda Execution Role (reusable) ---
resource "aws_iam_role" "lambda_execution" {
  name                 = "${var.environment}-lambda-execution-role"
  permissions_boundary = aws_iam_policy.permission_boundary.arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "lambda_security" {
  name = "${var.environment}-lambda-security-policy"
  role = aws_iam_role.lambda_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["securityhub:BatchImportFindings", "securityhub:GetFindings"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["guardduty:GetFindings", "guardduty:ListFindings"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutPublicAccessBlock", "s3:GetBucketPublicAccessBlock"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = "arn:aws:sns:*:*:${var.environment}-security-alerts"
      }
    ]
  })
}

output "cicd_deploy_role_arn"      { value = aws_iam_role.cicd_deploy.arn }
output "lambda_execution_role_arn" { value = aws_iam_role.lambda_execution.arn }
output "permission_boundary_arn"   { value = aws_iam_policy.permission_boundary.arn }
