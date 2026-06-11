#!/bin/bash
# scripts/deploy-openshift.sh
set -euo pipefail

ENV="${1:-dev}"
NAMESPACE="${NAMESPACE:-mytutorial}"

echo "=== Deploying MyTutorial to OpenShift (${ENV}) ==="
echo ""

# Ensure logged in
oc whoami > /dev/null 2>&1 || { echo "ERROR: Not logged into OpenShift. Run oc login first."; exit 1; }

# 1. Create project
echo "--- Creating/selecting project ${NAMESPACE} ---"
oc new-project "${NAMESPACE}" --skip-config-write=true 2>/dev/null || oc project "${NAMESPACE}"
echo ""

# 2. Create service account
echo "--- Setting up service account + SCC ---"
oc create sa mytutorial-sa -n "${NAMESPACE}" --dry-run=client -o yaml | oc apply -f -
oc adm policy add-scc-to-user anyuid -z mytutorial-sa -n "${NAMESPACE}" 2>/dev/null || true
echo ""

# 3. Create ImageStreams
echo "--- Creating ImageStreams ---"
kubectl apply -f base/imagestreams.yaml -n "${NAMESPACE}" 2>/dev/null || true
echo ""

# 4. Deploy infrastructure
echo "--- Deploying infrastructure ---"
kubectl apply -f infrastructure/ -n "${NAMESPACE}"
echo ""

# 5. Wait for infrastructure
echo "--- Waiting for infrastructure pods ---"
kubectl wait --for=condition=ready pod -l app=postgres -n "${NAMESPACE}" --timeout=120s 2>/dev/null || echo "  Postgres not ready yet (continuing...)"
kubectl wait --for=condition=ready pod -l app=redis -n "${NAMESPACE}" --timeout=60s 2>/dev/null || echo "  Redis not ready yet (continuing...)"
echo ""

# 6. Deploy application with kustomize
echo "--- Deploying application (${ENV}) ---"
kustomize build "overlays/${ENV}" | kubectl apply -n "${NAMESPACE}" -f -
echo ""

# 7. Wait for application
echo "--- Waiting for application pods ---"
for svc in eureka-server auth-service grades-service notification-service api-gateway; do
  echo "  Waiting for ${svc}..."
  oc rollout status "deploymentconfig/${svc}" -n "${NAMESPACE}" --timeout=180s 2>/dev/null || \
    kubectl rollout status "deployment/${svc}" -n "${NAMESPACE}" --timeout=180s 2>/dev/null || \
    echo "  ${svc} rollout timed out"
done
echo ""

# 8. Create routes
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

# 9. Summary
echo ""
echo "=== Deployment complete ==="
echo ""
echo "Routes:"
oc get routes -n "${NAMESPACE}" -o custom-columns=NAME:.metadata.name,URL:.spec.host 2>/dev/null || true
echo ""
echo "Verify:"
echo "  curl -k https://$(oc get route api-gateway -n ${NAMESPACE} --template='{{ .spec.host }}' 2>/dev/null || echo 'route-not-found')/actuator/health"