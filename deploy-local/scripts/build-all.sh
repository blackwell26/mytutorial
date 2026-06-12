#!/bin/bash
# scripts/build-all.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../backend" && pwd)"

echo "=== Building all MyTutorial images into Minikube ==="
echo ""

# Verify required tools
command -v minikube >/dev/null 2>&1 || { echo "ERROR: minikube not found. Install: sudo dnf install minikube"; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found. Install: sudo dnf install docker-ce"; exit 1; }

# Ensure minikube is running
minikube status 2>/dev/null | grep -q "Running" || {
  echo "ERROR: Minikube is not running. Start it first: minikube start"
  exit 1
}

# Verify Docker can talk to Minikube's daemon
if ! docker info >/dev/null 2>&1; then
  echo "ERROR: Cannot connect to Docker daemon."
  echo "  On CentOS 9, ensure your user is in the 'docker' group:"
  echo "    sudo usermod -aG docker \$USER && newgrp docker"
  echo "  Or run the script with: sudo -E $(basename "$0")"
  exit 1
fi

# Point to minikube's Docker daemon
eval "$(minikube docker-env)"

# Verify we're in minikube's Docker
if ! docker info 2>/dev/null | grep -qi "minikube"; then
  echo "ERROR: Docker not pointed at minikube. Run: eval \$(minikube docker-env)"
  exit 1
fi

# Build backend services
cd "$PROJECT_DIR"

for svc in eureka-server auth-service grades-service notification-service api-gateway; do
  echo "--- Building $svc ---"
  docker build \
    -f "$svc/Dockerfile" \
    -t "mytutorial/$svc:latest" \
    . 2>&1 | tail -n 1
done

cd "$SCRIPT_DIR"

# Verify images
echo ""
echo "=== Images in Minikube's Docker ==="
docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}" | grep mytutorial

echo ""
echo "=== Build complete ==="