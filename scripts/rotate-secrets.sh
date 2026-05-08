#!/usr/bin/env bash
# Trigger manual secret rotation for all managed secrets.
set -euo pipefail

ENVIRONMENT="${1:-prod}"
REGION="${AWS_REGION:-us-east-1}"

echo "Rotating secrets for environment: $ENVIRONMENT"

SECRETS=$(aws secretsmanager list-secrets \
  --region "$REGION" \
  --filters Key=name,Values="$ENVIRONMENT/" \
  --query 'SecretList[].Name' \
  --output text)

for SECRET in $SECRETS; do
  echo "Rotating: $SECRET"
  aws secretsmanager rotate-secret \
    --secret-id "$SECRET" \
    --region "$REGION" || echo "Warning: rotation failed for $SECRET (may not have rotation configured)"
done

echo "Rotation triggered for all secrets in $ENVIRONMENT"
