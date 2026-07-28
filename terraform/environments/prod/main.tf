terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # The state bucket and lock table are created out of band by
  # scripts/bootstrap.sh. Terraform cannot create the bucket that holds its own
  # state, so this configuration deliberately does not manage them.
  backend "s3" {
    bucket         = "devsecops-aws-tfstate-prod"
    key            = "prod/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = local.environment
      Project     = "devsecops-aws"
      ManagedBy   = "terraform"
    }
  }
}

locals {
  environment = "prod"
}

module "kms" {
  source      = "../../modules/kms"
  environment = local.environment
}

module "s3_access_logs" {
  source               = "../../modules/s3"
  environment          = local.environment
  bucket_name          = "devsecops-aws-s3-access-logs-${local.environment}"
  kms_key_arn          = module.kms.key_arn
  is_access_log_bucket = true
}

module "s3_logs" {
  source                = "../../modules/s3"
  environment           = local.environment
  bucket_name           = "devsecops-aws-logs-${local.environment}"
  kms_key_arn           = module.kms.key_arn
  access_log_bucket_id  = module.s3_access_logs.bucket_id
  log_delivery_services = ["cloudtrail", "config", "alb"]

  # Audit evidence must survive an attacker or an operator with delete rights.
  object_lock_enabled        = true
  object_lock_retention_days = 365
}

module "vpc" {
  source      = "../../modules/vpc"
  environment = local.environment
  cidr_block  = "10.2.0.0/16"
  kms_key_arn = module.kms.key_arn

  az_count           = 3
  single_nat_gateway = false
  eks_cluster_name   = "${local.environment}-cluster"
}

module "cloudtrail" {
  source        = "../../modules/cloudtrail"
  environment   = local.environment
  kms_key_arn   = module.kms.key_arn
  s3_bucket_arn = module.s3_logs.bucket_arn
  s3_bucket_id  = module.s3_logs.bucket_id
}

module "aws_config" {
  source       = "../../modules/aws-config"
  environment  = local.environment
  s3_bucket_id = module.s3_logs.bucket_id
  kms_key_arn  = module.kms.key_arn
}

module "security_hub" {
  source      = "../../modules/security-hub"
  environment = local.environment
  enable_pci  = true
  enable_nist = true
}

module "guardduty" {
  source      = "../../modules/guardduty"
  environment = local.environment
}

module "waf" {
  source      = "../../modules/waf"
  environment = local.environment
  kms_key_arn = module.kms.key_arn
}

module "iam" {
  source      = "../../modules/iam"
  environment = local.environment
}

module "ecr" {
  source       = "../../modules/ecr"
  environment  = local.environment
  kms_key_arn  = module.kms.key_arn
  repositories = ["api", "frontend", "worker", "ui", "catalog", "cart", "checkout", "orders"]
}

module "eks" {
  source          = "../../modules/eks"
  environment     = local.environment
  cluster_version = var.eks_cluster_version
  vpc_id          = module.vpc.vpc_id
  subnet_ids      = module.vpc.private_subnet_ids
  kms_key_arn     = module.kms.key_arn

  node_instance_types = ["m6i.large"]
  node_desired_size   = 3
  node_min_size       = 3
  node_max_size       = 12
}

module "ecs" {
  source             = "../../modules/ecs"
  environment        = local.environment
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  kms_key_arn        = module.kms.key_arn
  app_image          = "${module.ecr.repository_urls["api"]}:latest"
  access_logs_bucket = module.s3_logs.bucket_id
  alb_ingress_cidrs  = [module.vpc.vpc_cidr_block]
  certificate_arn    = var.certificate_arn
  min_capacity       = 3
  max_capacity       = 20
}

# Attaching the web ACL is what actually puts WAF in the request path. Creating
# the ACL alone inspects nothing.
resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = module.ecs.alb_arn
  web_acl_arn  = module.waf.web_acl_arn
}

module "monitoring" {
  source                    = "../../modules/monitoring"
  environment               = local.environment
  aws_region                = var.aws_region
  kms_key_arn               = module.kms.key_arn
  sns_alarm_arn             = module.security_hub.sns_topic_arn
  eks_cluster_name          = module.eks.cluster_name
  ecs_cluster_name          = module.ecs.cluster_name
  cloudtrail_log_group_name = module.cloudtrail.log_group_name
}
