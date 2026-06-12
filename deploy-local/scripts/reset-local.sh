#!/bin/bash
# scripts/reset-local.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../backend" && pwd)"

echo "╔══════════════════════════════════════════════════╗"
echo "║   WARNING: This will destroy everything!        ║"
echo "║   Minikube will be deleted and recreated.       ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
read -r -p "Are you sure? (y/N): " confirm

if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
  echo "Cancelled."
  exit 0
fi

# Verify required tools
command -v minikube >/dev/null 2>&1 || { echo "ERROR: minikube not found"; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found"; exit 1; }

echo ""
echo "=== Deleting Minikube cluster ==="
minikube delete
echo ""

echo "=== Starting fresh Minikube cluster ==="
minikube start --cpus 4 --memory 8192 --disk-size 20g
echo ""

echo "=== Enabling addons ==="
minikube addons enable ingress
minikube addons enable metrics-server
minikube addons enable dashboard
echo ""

echo "=== Building images (host Docker, then load into minikube) ==="
cd "$PROJECT_DIR"
for svc in eureka-server auth-service grades-service notification-service api-gateway; do
  echo "  Building $svc..."
  docker build -f "$svc/Dockerfile" -t "mytutorial/$svc:latest" . 2>&1 | tail -n 1
done
cd "$SCRIPT_DIR"
echo ""

echo "--- Loading images into Minikube ---"
for svc in eureka-server auth-service grades-service notification-service api-gateway; do
  echo "  Loading mytutorial/$svc:latest..."
  minikube image load "mytutorial/$svc:latest" 2>&1 | tail -n 1
done
echo ""

echo ""
echo "=== Minikube reset complete ==="
echo "Run the following to deploy:"
echo "  ./scripts/deploy-local.sh dev"