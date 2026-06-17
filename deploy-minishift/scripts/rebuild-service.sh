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
command -v minishift >/dev/null 2>&1 || { echo "ERROR: minishift not found"; exit 1; }
command -v oc >/dev/null 2>&1 || { echo "ERROR: oc not found"; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found"; exit 1; }

echo "=== Rebuilding and restarting ${SERVICE} ==="

# Ensure minishift is running
minishift_status=$(minishift status 2>/dev/null || true)
if ! echo "$minishift_status" | grep -q "Running"; then
  echo "ERROR: Minishift is not running. Start it first: minishift start"
  exit 1
fi

# Ensure logged in
oc whoami > /dev/null 2>&1 || { echo "ERROR: Not logged into OpenShift."; exit 1; }

# Build the image
cd "$PROJECT_DIR"

if [ ! -f "${SERVICE}/Dockerfile" ]; then
  echo "ERROR: No Dockerfile found at backend/${SERVICE}/Dockerfile"
  exit 1
fi

echo "--- Building ${SERVICE} ---"
docker build -f "${SERVICE}/Dockerfile" -t "mytutorial/${SERVICE}:latest" . 2>&1 | tail -n 1
echo ""

# Push to Minishift registry
REGISTRY="${MINISHIFT_IP:-$(minishift ip)}:5000"
echo "--- Tagging and pushing to Minishift registry ---"
docker tag "mytutorial/${SERVICE}:latest" "${REGISTRY}/${NAMESPACE}/${SERVICE}:latest"
docker push "${REGISTRY}/${NAMESPACE}/${SERVICE}:latest" 2>&1 | tail -n 1

# Update ImageStream
oc tag --source=docker "${REGISTRY}/${NAMESPACE}/${SERVICE}:latest" "${SERVICE}:latest" -n "${NAMESPACE}" 2>/dev/null || true
echo ""

cd "$SCRIPT_DIR"

# Trigger a new deployment
echo "--- Triggering new deployment ---"
# DeploymentConfig with ImageChange trigger will auto-deploy when the imagestreamtag updates.
# Force a rollout to pick up the new image immediately.
oc rollout latest "dc/${SERVICE}" -n "${NAMESPACE}" 2>/dev/null || \
  oc rollout restart "deploymentconfig/${SERVICE}" -n "${NAMESPACE}" 2>/dev/null || true

# Wait for rollout
echo "--- Waiting for rollout ---"
oc rollout status "dc/${SERVICE}" -n "${NAMESPACE}" --timeout=120s

echo ""
echo "=== ${SERVICE} rebuilt and restarted ==="
