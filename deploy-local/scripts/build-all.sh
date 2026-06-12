#!/bin/bash
# scripts/build-all.sh
set -euo pipefail

echo "=== Building all MyTutorial images into Minikube ==="
echo ""

# Ensure minikube is running
minikube status 2>/dev/null | grep -q "Running" || {
  echo "ERROR: Minikube is not running. Start it first: minikube start"
  exit 1
}

# Point to minikube's Docker daemon
eval $(minikube docker-env)

# Build backend services
cd ../../backend

for svc in eureka-server auth-service grades-service notification-service api-gateway; do
  echo "--- Building $svc ---"
  docker build \
    -f "$svc/Dockerfile" \
    -t "mytutorial/$svc:latest" \
    . 2>&1 | tail -1
done

cd ../"deploy-local"

# Verify images
echo ""
echo "=== Images in Minikube's Docker ==="
docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}" | grep mytutorial

echo ""
echo "=== Build complete ==="