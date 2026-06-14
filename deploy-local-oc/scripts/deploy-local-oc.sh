#!/bin/bash
# scripts/deploy-local-oc.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ENV="${1:-dev}"
NAMESPACE="${NAMESPACE:-mytutorial}"

echo "=== Deploying MyTutorial to local OpenShift (${ENV}) ==="
echo ""

# Verify required tools
command -v oc >/dev/null 2>&1 || { echo "ERROR: oc not found"; exit 1; }
command -v kustomize >/dev/null 2>&1 || { echo "ERROR: kustomize not found"; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found"; exit 1; }

# Ensure logged into OpenShift
oc whoami > /dev/null 2>&1 || { echo "ERROR: Not logged into OpenShift. Run oc login first."; exit 1; }

# 1. Create/select project
echo "--- Creating/selecting project ${NAMESPACE} ---"
oc new-project "${NAMESPACE}" --skip-config-write=true 2>/dev/null || oc project "${NAMESPACE}"
echo ""

# 2. Setup service account + SCC
echo "--- Setting up service account + SCC ---"
oc create sa mytutorial-sa -n "${NAMESPACE}" --dry-run=client -o yaml | oc apply -f -
oc adm policy add-scc-to-user anyuid -z mytutorial-sa -n "${NAMESPACE}" 2>/dev/null || true
oc adm policy add-scc-to-user fsgroup -z mytutorial-sa -n "${NAMESPACE}" 2>/dev/null || true
echo ""

# 3. Create ImageStreams
echo "--- Creating ImageStreams ---"
kustomize build "$BASE_DIR/base" 2>/dev/null | oc apply -f - -n "${NAMESPACE}" 2>/dev/null || \
  oc apply -f "$BASE_DIR/base/imagestreams.yaml" -n "${NAMESPACE}" 2>/dev/null || true
echo ""

# 4. Deploy infrastructure
echo "--- Deploying infrastructure (Postgres, Redis, Kafka) ---"
if [ -d "$BASE_DIR/infrastructure" ]; then
  oc apply -f "$BASE_DIR/infrastructure/" -n "${NAMESPACE}"
else
  echo "  WARNING: Infrastructure directory not found"
fi
echo ""

# 5. Wait for infrastructure
echo "--- Waiting for infrastructure pods ---"
oc wait --for=condition=ready pod -l app=postgres -n "${NAMESPACE}" --timeout=120s 2>/dev/null || echo "  Postgres not ready yet (continuing...)"
oc wait --for=condition=ready pod -l app=redis -n "${NAMESPACE}" --timeout=60s 2>/dev/null || echo "  Redis not ready yet (continuing...)"
echo ""

# 6. Deploy application with kustomize
echo "--- Deploying application (${ENV}) ---"
kustomize build "$BASE_DIR/overlays/${ENV}" | oc apply -n "${NAMESPACE}" -f -
echo ""

# 7. Wait for application rollouts
echo "--- Waiting for application rollouts ---"
for svc in eureka-server auth-service grades-service notification-service api-gateway; do
  echo "  Waiting for ${svc}..."
  oc rollout status "deploymentconfig/${svc}" -n "${NAMESPACE}" --timeout=180s 2>/dev/null || \
    oc rollout status "deployment/${svc}" -n "${NAMESPACE}" --timeout=180s 2>/dev/null || \
    echo "  ${svc} rollout timed out"
done
echo ""

# 8. Summary
echo "=== Deployment complete ==="
echo ""
echo "Routes:"
oc get routes -n "${NAMESPACE}" -o custom-columns=NAME:.metadata.name,URL:.spec.host 2>/dev/null || true
echo ""
echo "Access the application:"
echo "  Get route: oc get route api-gateway -n ${NAMESPACE} --template='https://{{ .spec.host }}'"
echo ""
echo "Verify health:"
echo "  curl -k https://\$(oc get route api-gateway -n ${NAMESPACE} --template='{{ .spec.host }}' 2>/dev/null)/actuator/health"