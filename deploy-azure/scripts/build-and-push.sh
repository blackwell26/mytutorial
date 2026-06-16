#!/bin/bash
# scripts/build-and-push.sh
set -euo pipefail

REGISTRY=${REGISTRY:-""}
TAG=${TAG:-"latest"}
SERVICES=("eureka-server" "auth-service" "grades-service" "notification-service" "api-gateway")

if [ -z "$REGISTRY" ]; then
  echo "ERROR: REGISTRY is required. Set your Azure Container Registry name."
  echo ""
  echo "Usage: REGISTRY=myacr.azurecr.io ./deploy-azure/scripts/build-and-push.sh"
  echo ""
  echo "To create an ACR:"
  echo "  az acr create --resource-group my-rg --name myacr --sku Basic"
  echo "  az acr login --name myacr"
  exit 1
fi

echo "=== Building & pushing MyTutorial images to Azure Container Registry ==="
echo "Registry: ${REGISTRY}"
echo "Tag:      ${TAG}"
echo ""

# Login to ACR (uses Azure CLI token — requires az login)
if command -v docker &> /dev/null; then
  # Try ACR login helper first, then Docker login
  acr_login_server=$(echo "$REGISTRY" | cut -d'/' -f1)
  az acr login --name "${acr_login_server%.azurecr.io}" 2>/dev/null || \
    docker login "$REGISTRY" 2>/dev/null || \
    echo "  Warning: Could not log into ACR. Make sure you're authenticated."
fi

for service in "${SERVICES[@]}"; do
  echo "--- Building ${service} ---"
  docker build \
    -f "backend/${service}/Dockerfile" \
    -t "${REGISTRY}/mytutorial/${service}:${TAG}" \
    -t "${REGISTRY}/mytutorial/${service}:latest" \
    ./backend

  echo "--- Pushing ${service} ---"
  docker push "${REGISTRY}/mytutorial/${service}:${TAG}"
  docker push "${REGISTRY}/mytutorial/${service}:latest"

  echo ""
done

echo "=== All images built and pushed ==="
echo ""
echo "Update image tags in deploy-azure/base/deployments.yaml if using a custom tag,"
echo "then run: ./deploy-azure/scripts/deploy.sh dev"
