#!/usr/bin/env bash
# Bootstrap Terraform remote state backend for each environment.
# Run once per environment before first terraform init.
set -euo pipefail

ENVIRONMENTS=("dev" "staging" "prod")
REGION="${AWS_REGION:-us-east-1}"
PROJECT="devsecops-aws"

for ENV in "${ENVIRONMENTS[@]}"; do
  BUCKET="${PROJECT}-tfstate-${ENV}"
  TABLE="terraform-state-lock"

  echo "=== Bootstrapping environment: ${ENV} ==="

  # Create S3 bucket
  if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
    echo "Bucket $BUCKET already exists"
  else
    aws s3api create-bucket \
      --bucket "$BUCKET" \
      --region "$REGION" \
      $([ "$REGION" != "us-east-1" ] && echo "--create-bucket-configuration LocationConstraint=$REGION" || echo "")
    echo "Created bucket: $BUCKET"
  fi

  # Enable versioning
  aws s3api put-bucket-versioning \
    --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled

  # Block public access
  aws s3api put-public-access-block \
    --bucket "$BUCKET" \
    --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

  # Enable encryption
  aws s3api put-bucket-encryption \
    --bucket "$BUCKET" \
    --server-side-encryption-configuration '{
      "Rules": [{
        "ApplyServerSideEncryptionByDefault": {
          "SSEAlgorithm": "aws:kms"
        },
        "BucketKeyEnabled": true
      }]
    }'

  # Enable access logging
  LOG_BUCKET="${PROJECT}-logs-${ENV}"
  aws s3api put-bucket-logging \
    --bucket "$BUCKET" \
    --bucket-logging-status "{
      \"LoggingEnabled\": {
        \"TargetBucket\": \"${LOG_BUCKET}\",
        \"TargetPrefix\": \"s3-access/tfstate/\"
      }
    }" 2>/dev/null || echo "Log bucket $LOG_BUCKET not yet created, skipping logging config"

  echo "Bucket $BUCKET configured"
done

# Create DynamoDB lock table (shared across environments)
TABLE="terraform-state-lock"
if aws dynamodb describe-table --table-name "$TABLE" --region "$REGION" 2>/dev/null; then
  echo "DynamoDB table $TABLE already exists"
else
  aws dynamodb create-table \
    --table-name "$TABLE" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$REGION" \
    --sse-specification Enabled=true
  echo "Created DynamoDB table: $TABLE"
fi

# Set up GitHub OIDC provider (run once per account)
echo ""
echo "=== Setting up GitHub Actions OIDC Provider ==="
OIDC_ARN=$(aws iam list-open-id-connect-providers \
  --query "OpenIDConnectProviderList[?ends_with(Arn,'token.actions.githubusercontent.com')].Arn" \
  --output text)

if [ -z "$OIDC_ARN" ]; then
  aws iam create-open-id-connect-provider \
    --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
  echo "Created GitHub OIDC provider"
else
  echo "GitHub OIDC provider already exists: $OIDC_ARN"
fi

echo ""
echo "Bootstrap complete! You can now run terraform init in each environment."
