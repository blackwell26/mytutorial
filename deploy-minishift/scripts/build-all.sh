#!/bin/bash
# scripts/build-all.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../backend" && pwd)"

echo "=== Building all MyTutorial images (host Docker) and importing into Minishift ==="
echo ""

# Verify required tools
command -v minishift >/dev/null 2>&1 || { echo "ERROR: minishift not found."; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found."; exit 1; }
command -v oc >/dev/null 2>&1 || { echo "ERROR: oc (OpenShift CLI) not found."; exit 1; }

# Verify Docker daemon is accessible
if ! docker info >/dev/null 2>&1; then
  echo "ERROR: Cannot connect to Docker daemon."
  exit 1
fi

# Ensure minishift is running
minishift_status=$(minishift status 2>/dev/null || true)
if ! echo "$minishift_status" | grep -q "Running"; then
  echo "ERROR: Minishift is not running. Start it: minishift start"
  exit 1
fi

# Ensure logged into OpenShift
oc whoami > /dev/null 2>&1 || { echo "ERROR: Not logged into OpenShift. Run oc login first."; exit 1; }

NAMESPACE="${NAMESPACE:-mytutorial}"

# Create project if not exists
oc new-project "${NAMESPACE}" --skip-config-write=true 2>/dev/null || oc project "${NAMESPACE}"

# Build backend services using host Docker
cd "$PROJECT_DIR"

for svc in eureka-server auth-service grades-service notification-service api-gateway; do
  echo "--- Building $svc ---"
  docker build \
    -f "$svc/Dockerfile" \
    -t "mytutorial/$svc:latest" \
    . 2>&1 | tail -n 1
done

cd "$SCRIPT_DIR"

# Tag and push images into Minishift's OpenShift internal registry
# Get registry host from minishift
REGISTRY_IP=$(minishift ip)
REGISTRY="${REGISTRY_IP}:5000"

# Login to the internal registry (uses the default OpenShift token)
echo ""
echo "--- Logging into Minishift internal registry ---"
docker login -u "$(oc whoami)" -p "$(oc whoami -t)" "${REGISTRY}" --tls-verify=false 2>/dev/null || \
  echo "  Warning: Could not log into registry. Trying podman..."

echo ""
echo "--- Pushing images to Minishift registry ---"
for svc in eureka-server auth-service grades-service notification-service api-gateway; do
  echo "  Tagging and pushing $svc..."
  docker tag "mytutorial/$svc:latest" "${REGISTRY}/${NAMESPACE}/${svc}:latest"
  docker push "${REGISTRY}/${NAMESPACE}/${svc}:latest" 2>&1 | tail -n 1
done

# Tag the images in OpenShift ImageStreams
echo ""
echo "--- Updating ImageStream tags ---"
for svc in eureka-server auth-service grades-service notification-service api-gateway; do
  oc tag --source=docker "${REGISTRY}/${NAMESPACE}/${svc}:latest" "${svc}:latest" -n "${NAMESPACE}" 2>/dev/null || true
done

# Verify
echo ""
echo "=== Images in ImageStreams ==="
for svc in eureka-server auth-service grades-service notification-service api-gateway; do
  echo "  ${NAMESPACE}/${svc}:latest"
  oc get imagestreamtag "${svc}:latest" -n "${NAMESPACE}" 2>/dev/null | tail -n 1 || echo "  (not yet imported)"
done

echo ""
echo "=== Build complete ==="
