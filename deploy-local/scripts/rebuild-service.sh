#!/bin/bash
# scripts/rebuild-service.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../backend" && pwd)"

SERVICE="${1:-}"
NAMESPACE="${NAMESPACE:-mytutorial}"

if [ -z "$SERVICE" ]; then
  echo "Usage: $0 <service-name>"
  echo "Available: eureka-server auth-service grades-service notification-service api-gateway"
  exit 1
fi

# Verify required tools
command -v minikube >/dev/null 2>&1 || { echo "ERROR: minikube not found"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl not found"; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found"; exit 1; }

echo "=== Rebuilding and restarting ${SERVICE} ==="

# Ensure minikube is running
minikube_status=$(minikube status 2>/dev/null || true)
if ! echo "$minikube_status" | grep -q "host:"; then
  echo "ERROR: Minikube is not running. Start it first: minikube start"
  exit 1
fi

# Build the image (host Docker, then load into minikube)
cd "$PROJECT_DIR"

if [ ! -f "${SERVICE}/Dockerfile" ]; then
  echo "ERROR: No Dockerfile found at backend/${SERVICE}/Dockerfile"
  exit 1
fi

echo "--- Building ${SERVICE} ---"
docker build -f "${SERVICE}/Dockerfile" -t "mytutorial/${SERVICE}:latest" . 2>&1 | tail -n 1
echo ""

echo "--- Loading image into Minikube ---"
minikube image load "mytutorial/${SERVICE}:latest" 2>&1 | tail -n 1
echo ""

cd "$SCRIPT_DIR"

# Restart the deployment
echo "--- Restarting deployment ---"
kubectl rollout restart "deployment/${SERVICE}" -n "${NAMESPACE}"

# Wait for rollout
echo "--- Waiting for rollout ---"
kubectl rollout status "deployment/${SERVICE}" -n "${NAMESPACE}" --timeout=120s

echo ""
echo "=== ${SERVICE} rebuilt and restarted ==="