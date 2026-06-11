#!/bin/bash
# scripts/reset-local.sh
set -euo pipefail

echo "╔══════════════════════════════════════════════════╗"
echo "║   WARNING: This will destroy everything!        ║"
echo "║   Minikube will be deleted and recreated.       ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
read -p "Are you sure? (y/N): " confirm

if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
  echo "Cancelled."
  exit 0
fi

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

echo "=== Building images ==="
eval $(minikube docker-env)
cd ../../backend
for svc in eureka-server auth-service grades-service notification-service api-gateway; do
  echo "  Building $svc..."
  docker build -f "$svc/Dockerfile" -t "mytutorial/$svc:latest" . 2>&1 | tail -1
done
cd ../"deploy local"
echo ""

echo ""
echo "=== Minikube reset complete ==="
echo "Run the following to deploy:"
echo "  ./scripts/deploy-local.sh dev"