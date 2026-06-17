#!/bin/bash
# scripts/reset-local.sh
set -euo pipefail

echo "=== Resetting MyTutorial on Minishift ==="
echo ""

# Verify minishift exists
command -v minishift >/dev/null 2>&1 || { echo "ERROR: minishift not found. Nothing to reset."; exit 1; }

echo "This will DELETE the Minishift VM and all data."
echo "  - The Minishift VM will be destroyed"
echo "  - All images, containers, and volumes will be removed"
echo "  - All OpenShift resources (projects, deployments, PVCs) will be lost"
echo ""

read -rp "Are you sure? Type 'yes' to continue: " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "Reset cancelled."
  exit 0
fi

echo ""
echo "--- Deleting Minishift VM ---"
minishift delete 2>&1 || true

# Clean up docker images tagged for minishift
echo ""
echo "--- Cleaning up Minishift-tagged Docker images ---"
REGISTRY_IP=$(minishift ip 2>/dev/null || echo "")
if [ -n "$REGISTRY_IP" ]; then
  docker images --format "{{.Repository}}:{{.Tag}} {{.ID}}" | grep "${REGISTRY_IP}" | awk '{print $2}' | xargs -r docker rmi -f 2>/dev/null || true
fi

echo ""
echo "=== Reset complete ==="
echo ""
echo "To redeploy, run:"
echo "  ./scripts/deploy-minishift.sh"
