terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
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
      Environment = "staging"
      Project     = "devsecops-aws"
      ManagedBy   = "terraform"
    }
  }
}

module "kms" {
  source      = "../../modules/kms"
  environment = "staging"
}

module "s3_logs" {
  source      = "../../modules/s3"
  environment = "staging"
  bucket_name = "devsecops-aws-logs-staging"
  kms_key_arn = module.kms.key_arn
}

module "vpc" {
  source      = "../../modules/vpc"
  environment = "staging"
  cidr_block  = "10.1.0.0/16"
}

module "cloudtrail" {
  source        = "../../modules/cloudtrail"
  environment   = "staging"
  kms_key_arn   = module.kms.key_arn
  s3_bucket_arn = module.s3_logs.bucket_arn
  s3_bucket_id  = module.s3_logs.bucket_id
}

module "aws_config" {
  source       = "../../modules/aws-config"
  environment  = "staging"
  s3_bucket_id = module.s3_logs.bucket_id
  kms_key_arn  = module.kms.key_arn
}

module "security_hub" {
  source      = "../../modules/security-hub"
  environment = "staging"
}

module "iam" {
  source      = "../../modules/iam"
  environment = "staging"
}

module "ecr" {
  source       = "../../modules/ecr"
  environment  = "staging"
  kms_key_arn  = module.kms.key_arn
  repositories = ["api", "frontend", "worker"]
}

module "eks" {
  source          = "../../modules/eks"
  environment     = "staging"
  cluster_version = "1.29"
  vpc_id          = module.vpc.vpc_id
  subnet_ids      = module.vpc.private_subnet_ids
}

module "ecs" {
  source             = "../../modules/ecs"
  environment        = "staging"
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  kms_key_arn        = module.kms.key_arn
  app_image          = "${module.ecr.repository_urls["api"]}:latest"
}
