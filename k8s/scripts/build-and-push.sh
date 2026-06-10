#!/bin/bash
set -euo pipefail

REGISTRY=${REGISTRY:-"localhost:5000"}
TAG=${TAG:-"latest"}

SERVICES=("eureka-server" "auth-service" "grades-service" "notification-service" "api-gateway")

echo "=== Building & pushing all backend Docker images ==="
echo "Registry: ${REGISTRY}"
echo "Tag:      ${TAG}"
echo ""

for service in "${SERVICES[@]}"; do
  echo "--- Building ${service} ---"
  docker build \
    -f "backend/${service}/Dockerfile" \
    -t "${REGISTRY}/mytutorial/${service}:${TAG}" \
    ./backend

  echo "--- Pushing ${service} ---"
  docker push "${REGISTRY}/mytutorial/${service}:${TAG}"

  echo ""
done

echo "=== All images built and pushed ==="
echo ""
echo "To deploy, update image tags in k8s/base/deployments.yaml or patches,"
echo "then run: kustomize build k8s/overlays/dev | kubectl apply -f -"