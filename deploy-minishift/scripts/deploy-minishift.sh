#!/bin/bash
# scripts/deploy-minishift.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../backend" && pwd)"
INFRA_DIR="$SCRIPT_DIR/../infrastructure"

ENV="${1:-dev}"
NAMESPACE="${NAMESPACE:-mytutorial}"

echo "=== Deploying MyTutorial to Minishift (${ENV}) ==="
echo ""

# Verify required tools
command -v minishift >/dev/null 2>&1 || { echo "ERROR: minishift not found"; exit 1; }
command -v oc >/dev/null 2>&1 || { echo "ERROR: oc not found"; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found"; exit 1; }
command -v kustomize >/dev/null 2>&1 || { echo "ERROR: kustomize not found"; exit 1; }

# 1. Start minishift if not running
echo "--- Checking Minishift status ---"
minishift_status=$(minishift status 2>/dev/null || true)
if ! echo "$minishift_status" | grep -q "Running"; then
  echo "--- Starting Minishift ---"
  minishift start --cpus 4 --memory 8192 --disk-size 20g
  echo ""
fi

# Ensure logged in
oc whoami > /dev/null 2>&1 || { echo "ERROR: Not logged into OpenShift. Run 'oc login' or 'minishift console' to get credentials."; exit 1; }

# 2. Create/select project
echo "--- Creating/selecting project ${NAMESPACE} ---"
oc new-project "${NAMESPACE}" --skip-config-write=true 2>/dev/null || oc project "${NAMESPACE}"
echo ""

# 3. Set up service account + SCC
echo "--- Setting up service account + SCC ---"
kubectl apply -f "$SCRIPT_DIR/../base/serviceaccount.yaml" -n "${NAMESPACE}" 2>/dev/null || true
oc adm policy add-scc-to-user anyuid -z mytutorial-sa -n "${NAMESPACE}" 2>/dev/null || true
echo ""

# 4. Create ImageStreams
echo "--- Creating ImageStreams ---"
kubectl apply -f "$SCRIPT_DIR/../base/imagestreams.yaml" -n "${NAMESPACE}" 2>/dev/null || true
echo ""

# 5. Build images (host Docker then push to minishift registry)
echo "--- Building images ---"
"$SCRIPT_DIR/build-all.sh"
echo ""

# 6. Deploy infrastructure
echo "--- Deploying infrastructure (Postgres, Redis, Kafka) ---"
if [ -d "$INFRA_DIR" ]; then
  kubectl apply -f "$INFRA_DIR/" -n "${NAMESPACE}"
else
  echo "  WARNING: Infrastructure directory not found at $INFRA_DIR"
fi
echo ""

# 7. Wait for infrastructure
echo "--- Waiting for infrastructure pods ---"
kubectl wait --for=condition=ready pod -l app=postgres -n "${NAMESPACE}" --timeout=120s 2>/dev/null || echo "  Postgres not ready yet (continuing...)"
kubectl wait --for=condition=ready pod -l app=redis -n "${NAMESPACE}" --timeout=60s 2>/dev/null || echo "  Redis not ready yet (continuing...)"
echo ""

# 8. Deploy application with kustomize
echo "--- Deploying application (${ENV}) ---"
kustomize build "$SCRIPT_DIR/../overlays/${ENV}" | kubectl apply -n "${NAMESPACE}" -f -
echo ""

# 9. Wait for application
echo "--- Waiting for application pods ---"
for svc in eureka-server auth-service grades-service notification-service api-gateway; do
  echo "  Waiting for ${svc}..."
  oc rollout status "deploymentconfig/${svc}" -n "${NAMESPACE}" --timeout=180s 2>/dev/null || \
    echo "  ${svc} rollout timed out"
done
echo ""

# 10. Deploy monitoring
echo "--- Deploying monitoring (Prometheus, Grafana, ELK) ---"
for manifest in prometheus grafana elk; do
  manifest_file="$INFRA_DIR/${manifest}.yaml"
  if [ -f "$manifest_file" ]; then
    kubectl apply -f "$manifest_file" -n "${NAMESPACE}" 2>/dev/null || true
  fi
done

# 11. Create routes
echo "--- Creating Routes ---"
for svc in api-gateway eureka-server auth-service; do
  oc create route edge "${svc}" --service="${svc}" --port=8080 -n "${NAMESPACE}" 2>/dev/null || true
done
# Fix api-gateway port
oc delete route api-gateway -n "${NAMESPACE}" 2>/dev/null || true
oc create route edge api-gateway \
  --service=api-gateway \
  --port=8080 \
  -n "${NAMESPACE}" \
  --insecure-policy=Redirect 2>/dev/null || true
echo ""

# 12. Summary
MINISHIFT_IP="$(minishift ip 2>/dev/null || echo '<minishift-ip>')"
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║              Deployment Complete                        ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║                                                        ║"
echo "║  Access the application:                               ║"
echo "║    OpenShift Console: $(minishift console --url 2>/dev/null || echo 'minishift console')  ║"
echo "║                                                        ║"
echo "║  Routes:                                               ║"
oc get routes -n "${NAMESPACE}" -o custom-columns=NAME:.metadata.name,URL:.spec.host 2>/dev/null || true
echo "║                                                        ║"
echo "║  Quick verify:                                         ║"
echo "║    curl -k https://api-gateway-${NAMESPACE}.${MINISHIFT_IP}.nip.io/actuator/health  ║"
echo "║                                                        ║"
echo "║  Monitoring:                                           ║"
echo "║    Prometheus: @ route 'prometheus'                    ║"
echo "║    Grafana:    @ route 'grafana'                       ║"
echo "║    OpenSearch: @ route 'opensearch-dashboards'         ║"
echo "║                                                        ║"
echo "╚══════════════════════════════════════════════════════════╝"
