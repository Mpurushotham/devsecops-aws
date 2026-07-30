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
    bucket         = "devsecops-aws-tfstate-staging"
    key            = "staging/terraform.tfstate"
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
  environment = "staging"
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
}

module "vpc" {
  source      = "../../modules/vpc"
  environment = local.environment
  cidr_block  = "10.1.0.0/16"
  kms_key_arn = module.kms.key_arn

  # Staging mirrors the production topology so NAT failure modes surface here
  # rather than in production.
  single_nat_gateway = false
  eks_cluster_name   = "${local.environment}-cluster"
}

module "cloudtrail" {
  source       = "../../modules/cloudtrail"
  environment  = local.environment
  kms_key_arn  = module.kms.key_arn
  s3_bucket_id = module.s3_logs.bucket_id
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
  kms_key_arn = module.kms.key_arn
}

module "guardduty" {
  source      = "../../modules/guardduty"
  environment = local.environment
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
  vpc_cidr_block  = module.vpc.vpc_cidr_block
  kms_key_arn     = module.kms.key_arn

  node_desired_size = 2
  node_min_size     = 2
  node_max_size     = 6
}

module "ecs" {
  source             = "../../modules/ecs"
  environment        = local.environment
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  vpc_cidr_block     = module.vpc.vpc_cidr_block
  s3_prefix_list_id  = module.vpc.s3_prefix_list_id
  kms_key_arn        = module.kms.key_arn
  app_image          = "${module.ecr.repository_urls["api"]}:latest"
  access_logs_bucket = module.s3_logs.bucket_id
  alb_ingress_cidrs  = [module.vpc.vpc_cidr_block]
  certificate_arn    = var.certificate_arn
}

module "monitoring" {
  source                    = "../../modules/monitoring"
  environment               = local.environment
  aws_region                = var.aws_region
  sns_alarm_arn             = module.security_hub.sns_topic_arn
  eks_cluster_name          = module.eks.cluster_name
  ecs_cluster_name          = module.ecs.cluster_name
  cloudtrail_log_group_name = module.cloudtrail.log_group_name
}
