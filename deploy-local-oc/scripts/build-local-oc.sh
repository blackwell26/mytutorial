#!/bin/bash
# scripts/build-local-oc.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../backend" && pwd)"
PROJECT="${PROJECT:-mytutorial}"

# Get external OpenShift registry URL (use --public for host-side access)
PUBLIC_REGISTRY="${PUBLIC_REGISTRY:-$(oc registry info --public 2>/dev/null)}"
REGISTRY="${REGISTRY:-${PUBLIC_REGISTRY:-$(oc registry info 2>/dev/null)}}"
if [ -z "$REGISTRY" ]; then
  echo "ERROR: Could not determine OpenShift registry URL. Ensure you're logged in."
  exit 1
fi
SERVICES=("eureka-server" "auth-service" "grades-service" "notification-service" "api-gateway")

echo "=== Building & pushing MyTutorial images to OpenShift Internal Registry ==="
echo ""

# Ensure logged in
oc whoami > /dev/null 2>&1 || { echo "ERROR: Not logged into OpenShift. Run oc login first."; exit 1; }

# Ensure project exists
oc get project "${PROJECT}" > /dev/null 2>&1 || oc new-project "${PROJECT}" --skip-config-write=true

# Login to registry
echo "--- Logging into registry: ${REGISTRY} ---"
podman login -u "$(oc whoami)" -p "$(oc whoami -t)" "${REGISTRY}" --tls-verify=false 2>/dev/null || \
  docker login -u "$(oc whoami)" -p "$(oc whoami -t)" "${REGISTRY}" --tls-verify=false 2>/dev/null || {
  echo "  Warning: Could not log into registry."
}

echo ""

# Build and push each service
cd "$PROJECT_DIR"

for svc in "${SERVICES[@]}"; do
  echo "--- ${svc} ---"

  TAG=$(git rev-parse --short HEAD 2>/dev/null || echo "latest")

  echo "  Building ${svc}:${TAG}..."
  docker build \
    -f "${svc}/Dockerfile" \
    -t "${REGISTRY}/${PROJECT}/${svc}:${TAG}" \
    -t "${REGISTRY}/${PROJECT}/${svc}:latest" \
    .

  echo "  Pushing ${svc}:${TAG}..."
  docker push "${REGISTRY}/${PROJECT}/${svc}:${TAG}" 2>&1 | tail -1
  docker push "${REGISTRY}/${PROJECT}/${svc}:latest" 2>&1 | tail -1

  echo ""
done

cd "$SCRIPT_DIR"

echo ""
echo "=== Build complete ==="
docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}" | grep "${PROJECT}"