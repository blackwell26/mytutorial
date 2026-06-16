#!/bin/bash
# scripts/build.sh — Build Docker images for Lambda and push to ECR
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../backend" && pwd)"
SERVERLESS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ENV="${1:-dev}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ECR_REPO_PREFIX="${ECR_REPO_PREFIX:-mytutorial}"

SERVICES=("auth-service" "grades-service" "notification-service")

echo "=== Building MyTutorial serverless images for ${ENV} ==="
echo "Region: ${AWS_REGION}"
echo "Repo prefix: ${ECR_REPO_PREFIX}"
echo ""

# Authenticate with ECR
echo "--- Logging into ECR ---"
aws ecr get-login-password --region "${AWS_REGION}" | \
  docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# Create ECR repos if they don't exist
for svc in "${SERVICES[@]}"; do
  REPO_NAME="${ECR_REPO_PREFIX}-${ENV}-${svc}"
  aws ecr describe-repositories --repository-names "${REPO_NAME}" --region "${AWS_REGION}" &>/dev/null || \
    aws ecr create-repository \
      --repository-name "${REPO_NAME}" \
      --image-scanning-configuration scanOnPush=true \
      --region "${AWS_REGION}" \
      --tags Key=Environment,Value="${ENV}" Key=Project,Value=mytutorial
  echo "  [OK] ECR repo: ${REPO_NAME}"
done

echo ""

# Build and push each service
for svc in "${SERVICES[@]}"; do
  echo "--- ${svc} ---"

  IMAGE_TAG="latest"
  REPO_NAME="${ECR_REPO_PREFIX}-${ENV}-${svc}"
  IMAGE_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${REPO_NAME}:${IMAGE_TAG}"

  echo "  Building..."
  docker build \
    -f "${SERVERLESS_DIR}/services/${svc}/Dockerfile" \
    -t "${IMAGE_URI}" \
    "${PROJECT_DIR}/.."  # repo root (needs backend/ as context)

  echo "  Pushing..."
  docker push "${IMAGE_URI}"

  echo ""
done

echo "=== Build complete ==="
echo ""
echo "Update template.yaml ImageUri references or deploy with:"
echo "  sam deploy --template-file template.yaml --parameter-overrides Environment=${ENV}"
echo ""
echo "Or use scripts/deploy.sh:"
echo "  ./deploy-serverless/scripts/deploy.sh ${ENV}"
