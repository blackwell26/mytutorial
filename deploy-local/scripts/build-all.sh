#!/bin/bash
# scripts/build-all.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../backend" && pwd)"

echo "=== Building all MyTutorial images (host Docker) and loading into Minikube ==="
echo ""

# Verify required tools
command -v minikube >/dev/null 2>&1 || { echo "ERROR: minikube not found."; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found."; exit 1; }

# Verify Docker daemon is accessible (host Docker, not minikube's)
if ! docker info >/dev/null 2>&1; then
  echo "ERROR: Cannot connect to Docker daemon."
  echo "  On CentOS 9, ensure your user is in the 'docker' group:"
  echo "    sudo usermod -aG docker \$USER && newgrp docker"
  exit 1
fi

# Ensure minikube is running (check just the host, as kubelet may be stopped)
minikube_status=$(minikube status 2>/dev/null || true)
if ! echo "$minikube_status" | grep -q "host:"; then
  echo "ERROR: Minikube is not running. Start it: minikube start"
  exit 1
fi

# Build backend services using host Docker daemon (minikube's Docker has no DNS)
cd "$PROJECT_DIR"

for svc in eureka-server auth-service grades-service notification-service api-gateway; do
  echo "--- Building $svc ---"
  docker build \
    -f "$svc/Dockerfile" \
    -t "mytutorial/$svc:latest" \
    . 2>&1 | tail -n 1
done

cd "$SCRIPT_DIR"

# Load images into minikube
echo ""
echo "--- Loading images into Minikube ---"
for svc in eureka-server auth-service grades-service notification-service api-gateway; do
  echo "Loading mytutorial/$svc:latest..."
  minikube image load "mytutorial/$svc:latest" 2>&1 | tail -n 1
done

# Verify images
echo ""
echo "=== Images in Minikube ==="
minikube image ls --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}" 2>/dev/null | grep mytutorial || \
  minikube image ls | grep mytutorial

echo ""
echo "=== Build complete ==="
