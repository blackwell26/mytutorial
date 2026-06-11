#!/bin/bash
# scripts/rebuild-service.sh
set -euo pipefail

SERVICE="${1:-}"
NAMESPACE="${NAMESPACE:-mytutorial}"

if [ -z "$SERVICE" ]; then
  echo "Usage: $0 <service-name>"
  echo "Available: eureka-server auth-service grades-service notification-service api-gateway"
  exit 1
fi

echo "=== Rebuilding and restarting ${SERVICE} ==="

# Build the image
eval $(minikube docker-env)
cd ../../backend

if [ ! -f "${SERVICE}/Dockerfile" ]; then
  echo "ERROR: No Dockerfile found at backend/${SERVICE}/Dockerfile"
  exit 1
fi

echo "--- Building ${SERVICE} ---"
docker build -f "${SERVICE}/Dockerfile" -t "mytutorial/${SERVICE}:latest" .
echo ""

cd ../"deploy local"

# Restart the deployment
echo "--- Restarting deployment ---"
kubectl rollout restart "deployment/${SERVICE}" -n "${NAMESPACE}"

# Wait for rollout
echo "--- Waiting for rollout ---"
kubectl rollout status "deployment/${SERVICE}" -n "${NAMESPACE}" --timeout=120s

echo ""
echo "=== ${SERVICE} rebuilt and restarted ==="