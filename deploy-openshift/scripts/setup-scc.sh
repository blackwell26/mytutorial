#!/bin/bash
# scripts/setup-scc.sh
set -euo pipefail

NAMESPACE="${1:-mytutorial}"
SERVICE_ACCOUNT="${2:-mytutorial-sa}"

echo "=== Setting up SCC for ${NAMESPACE}/${SERVICE_ACCOUNT} ==="
echo ""

# Ensure cluster admin
oc auth can-i create scc --all-namespaces > /dev/null 2>&1 || {
  echo "ERROR: You need cluster-admin privileges to manage SCC."
  echo "Run: oc login -u cluster-admin"
  exit 1
}

# Create service account
oc create sa "${SERVICE_ACCOUNT}" -n "${NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

# Apply anyuid SCC — allows JRE containers to run with their default UID
echo "1. Applying anyuid SCC..."
oc adm policy add-scc-to-user anyuid -z "${SERVICE_ACCOUNT}" -n "${NAMESPACE}"

# Apply fsgroup SCC — allows writing to PVCs
echo "2. Applying fsgroup SCC..."
oc adm policy add-scc-to-user fsgroup -z "${SERVICE_ACCOUNT}" -n "${NAMESPACE}"

# Apply nonroot SCC (alternative if anyuid is too permissive)
# echo "3. Applying nonroot SCC..."
# oc adm policy add-scc-to-user nonroot -z "${SERVICE_ACCOUNT}" -n "${NAMESPACE}"

echo ""
echo "=== Verification ==="
echo "SCCs for service account:"
oc get rolebinding -n "${NAMESPACE}" | grep scc || echo "  No specific SCC rolebindings found"
echo ""
echo "Test with:"
echo "  oc describe pod -n ${NAMESPACE} | grep openshift.io/scc"