#!/bin/bash
# scripts/deploy.sh — Deploy serverless stack with SAM
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVERLESS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ENV="${1:-dev}"
AWS_REGION="${AWS_REGION:-us-east-1}"
STACK_NAME="${STACK_NAME:-mytutorial-serverless-${ENV}}"
ECR_REPO_PREFIX="${ECR_REPO_PREFIX:-mytutorial}"
S3_BUCKET="${S3_BUCKET:-mytutorial-serverless-${ENV}-deploy}"

echo "=== Deploying MyTutorial Serverless (${ENV}) ==="
echo "Stack:     ${STACK_NAME}"
echo "Region:    ${AWS_REGION}"
echo ""

# Determine AWS account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Build images first (unless --skip-build passed)
if [[ "${2:-}" != "--skip-build" ]]; then
  echo "--- Building images ---"
  AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID}" "${SCRIPT_DIR}/build.sh" "${ENV}"
fi

# Create deployment S3 bucket if not exists
echo "--- Ensuring S3 bucket for SAM artifacts ---"
aws s3api head-bucket --bucket "${S3_BUCKET}" --region "${AWS_REGION}" 2>/dev/null || \
  aws s3 mb "s3://${S3_BUCKET}" --region "${AWS_REGION}"

# Package and deploy with SAM
echo "--- Deploying SAM stack ---"
cd "${SERVERLESS_DIR}"

# Build SAM templates (for the Node.js authorizer — Lambda functions use pre-built images)
sam build \
  --template template.yaml \
  --region "${AWS_REGION}"

sam deploy \
  --stack-name "${STACK_NAME}" \
  --s3-bucket "${S3_BUCKET}" \
  --s3-prefix "${ENV}/sam" \
  --region "${AWS_REGION}" \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    "Environment=${ENV}" \
    "JwtSecret=${JWT_SECRET:-3f8a2b1c9d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a}" \
    "DbPassword=${DB_PASSWORD:-mypassword}" \
  --no-fail-on-empty-changeset \
  --tags \
    Environment="${ENV}" \
    Project=mytutorial \
  --output-template-file packaged.yaml

echo ""
echo "=== Deployment complete ==="
echo ""

# Output the API endpoint
API_URL=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" \
  --region "${AWS_REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='ApiEndpoint'].OutputValue" \
  --output text 2>/dev/null || echo "pending...")

if [ -n "$API_URL" ] && [ "$API_URL" != "null" ]; then
  echo "API Gateway URL: ${API_URL}"
  echo ""
  echo "Test endpoints:"
  echo "  Signup:  curl -X POST ${API_URL}/api/signup -H 'Content-Type: application/json' -d '{\"username\":\"test\",\"email\":\"test@test.com\",\"password\":\"password\"}'"
  echo "  Signin:  curl -X POST ${API_URL}/api/signin -H 'Content-Type: application/json' -d '{\"username\":\"test\",\"password\":\"password\"}'"
  echo "  Grades:  curl ${API_URL}/api/grades -H 'Authorization: Bearer <token>'"
fi
