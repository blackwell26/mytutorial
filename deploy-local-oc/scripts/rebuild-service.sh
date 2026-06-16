#!/bin/bash
# scripts/rebuild-service.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../backend" && pwd)"
PROJECT="${PROJECT:-mytutorial}"

# Get external OpenShift registry URL (works from host, unlike internal svc URL)
REGISTRY="${REGISTRY:-$(oc registry info 2>/dev/null)}"
if [ -z "$REGISTRY" ]; then
  echo "ERROR: Could not determine OpenShift registry URL. Ensure you're logged in."
  exit 1
fi

SERVICE="${1:-}"
NAMESPACE="${NAMESPACE:-mytutorial}"

if [ -z "$SERVICE" ]; then
  echo "Usage: $0 <service-name>"
  echo "Available: eureka-server auth-service grades-service notification-service api-gateway"
  exit 1
fi

# Verify required tools
command -v oc >/dev/null 2>&1 || { echo "ERROR: oc not found"; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found"; exit 1; }

echo "=== Rebuilding and restarting ${SERVICE} ==="

# Ensure logged into OpenShift
oc whoami > /dev/null 2>&1 || { echo "ERROR: Not logged into OpenShift. Run oc login first."; exit 1; }

# Build the image
cd "$PROJECT_DIR"

if [ ! -f "${SERVICE}/Dockerfile" ]; then
  echo "ERROR: No Dockerfile found at backend/${SERVICE}/Dockerfile"
  exit 1
fi

TAG=$(git rev-parse --short HEAD 2>/dev/null || echo "latest")

echo "--- Building ${SERVICE}:${TAG} ---"
docker build \
  -f "${SERVICE}/Dockerfile" \
  -t "${REGISTRY}/${PROJECT}/${SERVICE}:${TAG}" \
  -t "${REGISTRY}/${PROJECT}/${SERVICE}:latest" \
  .

echo ""
echo "--- Pushing ${SERVICE} ---"
docker push "${REGISTRY}/${PROJECT}/${SERVICE}:${TAG}" 2>&1 | tail -1
docker push "${REGISTRY}/${PROJECT}/${SERVICE}:latest" 2>&1 | tail -1

echo ""
cd "$SCRIPT_DIR"

# Trigger a new rollout (DeploymentConfig auto-deploys on ImageStream change)
echo "--- Triggering rollout ---"
oc rollout latest "deploymentconfig/${SERVICE}" -n "${NAMESPACE}" 2>/dev/null || \
  oc rollout restart "deployment/${SERVICE}" -n "${NAMESPACE}" 2>/dev/null || \
  { echo "  Warning: Could not trigger rollout. Ensure the DeploymentConfig exists."; }

# Wait for rollout
echo "--- Waiting for rollout ---"
oc rollout status "deploymentconfig/${SERVICE}" -n "${NAMESPACE}" --timeout=120s 2>/dev/null || \
  oc rollout status "deployment/${SERVICE}" -n "${NAMESPACE}" --timeout=120s 2>/dev/null || \
  echo "  ${SERVICE} rollout timed out"

echo ""
echo "=== ${SERVICE} rebuilt and restarted ==="