#!/bin/bash
# scripts/reset-local-oc.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NAMESPACE="${NAMESPACE:-mytutorial}"

echo "=== Resetting MyTutorial on local OpenShift ==="
echo ""
echo "This will delete the entire project: ${NAMESPACE}"
echo "  - All deployments, services, routes, PVCs"
echo "  - All infrastructure (Postgres, Redis, Kafka)"
echo ""

read -p "Are you sure? (y/N): " confirm
if [ "${confirm}" != "y" ] && [ "${confirm}" != "Y" ]; then
  echo "Cancelled."
  exit 0
fi

echo ""
echo "--- Deleting project ${NAMESPACE} ---"
oc delete project "${NAMESPACE}" --wait=true 2>/dev/null || {
  echo "  Project does not exist or could not be deleted."
  echo "  Cleaning up resources directly..."
  oc delete all --all -n "${NAMESPACE}" 2>/dev/null || true
  oc delete pvc --all -n "${NAMESPACE}" 2>/dev/null || true
  oc delete configmap --all -n "${NAMESPACE}" 2>/dev/null || true
  oc delete serviceaccount --all -n "${NAMESPACE}" 2>/dev/null || true
  oc delete rolebinding --all -n "${NAMESPACE}" 2>/dev/null || true
  oc delete networkpolicy --all -n "${NAMESPACE}" 2>/dev/null || true
}

echo ""
echo "--- Rebuilding and redeploying ---"
echo ""
echo "Run the following to redeploy:"
echo "  ${SCRIPT_DIR}/deploy-local-oc.sh dev"
echo ""
echo "=== Reset complete ==="