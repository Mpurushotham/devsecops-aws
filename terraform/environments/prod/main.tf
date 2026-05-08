terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
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
      Environment = "prod"
      Project     = "devsecops-aws"
      ManagedBy   = "terraform"
    }
  }
}

module "kms" {
  source      = "../../modules/kms"
  environment = "prod"
}

module "s3_logs" {
  source      = "../../modules/s3"
  environment = "prod"
  bucket_name = "devsecops-aws-logs-prod"
  kms_key_arn = module.kms.key_arn
}

module "s3_tfstate" {
  source      = "../../modules/s3"
  environment = "prod"
  bucket_name = "devsecops-aws-tfstate-prod"
  kms_key_arn = module.kms.key_arn
}

module "vpc" {
  source      = "../../modules/vpc"
  environment = "prod"
  cidr_block  = "10.2.0.0/16"
}

module "cloudtrail" {
  source        = "../../modules/cloudtrail"
  environment   = "prod"
  kms_key_arn   = module.kms.key_arn
  s3_bucket_arn = module.s3_logs.bucket_arn
  s3_bucket_id  = module.s3_logs.bucket_id
}

module "aws_config" {
  source       = "../../modules/aws-config"
  environment  = "prod"
  s3_bucket_id = module.s3_logs.bucket_id
  kms_key_arn  = module.kms.key_arn
}

module "security_hub" {
  source       = "../../modules/security-hub"
  environment  = "prod"
  enable_pci   = true
  enable_nist  = true
}

module "guardduty" {
  source      = "../../modules/guardduty"
  environment = "prod"
}

module "waf" {
  source      = "../../modules/waf"
  environment = "prod"
}

module "iam" {
  source      = "../../modules/iam"
  environment = "prod"
}

module "ecr" {
  source        = "../../modules/ecr"
  environment   = "prod"
  kms_key_arn   = module.kms.key_arn
  repositories  = ["api", "frontend", "worker"]
}

module "eks" {
  source          = "../../modules/eks"
  environment     = "prod"
  cluster_version = "1.29"
  vpc_id          = module.vpc.vpc_id
  subnet_ids      = module.vpc.private_subnet_ids
}

module "ecs" {
  source             = "../../modules/ecs"
  environment        = "prod"
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  kms_key_arn        = module.kms.key_arn
  app_image          = "${module.ecr.repository_urls["api"]}:latest"
  min_capacity       = 3
  max_capacity       = 20
}

module "monitoring" {
  source           = "../../modules/monitoring"
  environment      = "prod"
  kms_key_arn      = module.kms.key_arn
  sns_alarm_arn    = module.security_hub.sns_topic_arn
  eks_cluster_name = module.eks.cluster_name
  ecs_cluster_name = module.ecs.cluster_name
}
