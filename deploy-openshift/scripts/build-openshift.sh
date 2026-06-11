#!/bin/bash
# scripts/build-openshift.sh
set -euo pipefail

PROJECT="${1:-mytutorial}"
SERVICES=("eureka-server" "auth-service" "grades-service" "notification-service" "api-gateway")

echo "=== Building & pushing MyTutorial images to OpenShift Internal Registry ==="
echo ""

# Ensure logged in
oc whoami > /dev/null 2>&1 || { echo "ERROR: Not logged into OpenShift. Run oc login first."; exit 1; }

# Get registry host
REGISTRY=$(oc get route default-route -n openshift-image-registry --template='{{ .spec.host }}' 2>/dev/null || \
           echo "image-registry.openshift-image-registry.svc:5000")

# Login to registry
echo "--- Logging into registry: ${REGISTRY} ---"
podman login -u "$(oc whoami)" -p "$(oc whoami -t)" "${REGISTRY}" --tls-verify=false 2>/dev/null || \
  docker login -u "$(oc whoami)" -p "$(oc whoami -t)" "${REGISTRY}" 2>/dev/null || \
  echo "  Warning: Could not log into registry. Build may fail."

echo ""

# Build and push each service
for svc in "${SERVICES[@]}"; do
  echo "--- ${svc} ---"
  cd ../../backend

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

  cd ../"deploy-openshift"

  # Tag the image in OpenShift's ImageStream
  oc tag "${REGISTRY}/${PROJECT}/${svc}:latest" "${svc}:latest" -n "${PROJECT}" 2>/dev/null || true

  echo ""
done

echo "=== Build complete ==="
docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}" | grep "${PROJECT}"