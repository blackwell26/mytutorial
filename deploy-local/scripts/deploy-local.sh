#!/bin/bash
# scripts/deploy-local.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../backend" && pwd)"
INFRA_DIR="$SCRIPT_DIR/../infrastructure"

ENV="${1:-dev}"
NAMESPACE="${NAMESPACE:-mytutorial}"

echo "=== Deploying MyTutorial to Minikube (${ENV}) ==="
echo ""

# Verify required tools
command -v minikube >/dev/null 2>&1 || { echo "ERROR: minikube not found"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl not found"; exit 1; }
command -v kustomize >/dev/null 2>&1 || { echo "ERROR: kustomize not found"; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found"; exit 1; }

# 1. Start minikube if not running
minikube_status=$(minikube status 2>/dev/null || true)
if ! echo "$minikube_status" | grep -q "host:"; then
  echo "--- Starting Minikube ---"
  minikube start --cpus 4 --memory 8192 --disk-size 20g
  echo ""
fi

# 2. Enable addons
echo "--- Enabling addons ---"
minikube addons enable ingress 2>/dev/null || true
minikube addons enable metrics-server 2>/dev/null || true
echo ""

# 3. Build images (host Docker, then load into minikube)
echo "--- Building images ---"
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

# 4. Create namespace
echo "--- Creating namespace ---"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
echo ""

# 5. Deploy infrastructure
echo "--- Deploying infrastructure (Postgres, Redis, Kafka) ---"
if [ -d "$INFRA_DIR" ]; then
  kubectl apply -f "$INFRA_DIR/" -n "${NAMESPACE}"
else
  echo "  WARNING: Infrastructure directory not found at $INFRA_DIR"
fi
echo ""

# 6. Wait for infrastructure
echo "--- Waiting for infrastructure pods ---"
kubectl wait --for=condition=ready pod -l app=postgres -n "${NAMESPACE}" --timeout=120s 2>/dev/null || echo "  Postgres not ready yet (continuing...)"
kubectl wait --for=condition=ready pod -l app=redis -n "${NAMESPACE}" --timeout=60s 2>/dev/null || echo "  Redis not ready yet (continuing...)"
echo ""

# 7. Deploy application
OVERLAY_DIR="$SCRIPT_DIR/../overlays/${ENV}"
if [ -d "$OVERLAY_DIR" ]; then
  echo "--- Deploying application (${ENV}) ---"
  kustomize build "$OVERLAY_DIR" | kubectl apply -n "${NAMESPACE}" -f -
else
  echo "  ERROR: Overlay directory not found: $OVERLAY_DIR"
  exit 1
fi
echo ""

# 8. Wait for application
echo "--- Waiting for application pods ---"
for svc in eureka-server auth-service grades-service notification-service api-gateway; do
  echo "  Waiting for $svc..."
  kubectl rollout status "deployment/$svc" -n "${NAMESPACE}" --timeout=180s 2>/dev/null || echo "  $svc rollout timed out"
done
echo ""

# 9. Deploy monitoring
echo "--- Deploying monitoring (Prometheus, Grafana, ELK) ---"
for manifest in prometheus grafana elk; do
  manifest_file="$INFRA_DIR/${manifest}.yaml"
  if [ -f "$manifest_file" ]; then
    kubectl apply -f "$manifest_file" -n "${NAMESPACE}" 2>/dev/null || true
  fi
done

# 10. Summary
MINIKUBE_IP="$(minikube ip 2>/dev/null || echo '<minikube-ip>')"
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║              Deployment Complete                        ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║                                                        ║"
echo "║  Access the application:                               ║"
echo "║    kubectl port-forward -n ${NAMESPACE} service/api-gateway 8080:80  ║"
echo "║    curl http://localhost:8080/actuator/health          ║"
echo "║                                                        ║"
echo "║  Access monitoring:                                    ║"
echo "║    Prometheus:   kubectl port-forward -n ${NAMESPACE} service/prometheus 9090:9090 ║"
echo "║    Grafana:      kubectl port-forward -n ${NAMESPACE} service/grafana 3000:3000    ║"
echo "║    OpenSearch:   kubectl port-forward -n ${NAMESPACE} service/opensearch-dashboards 5601:5601 ║"
echo "║                                                        ║"
echo "║  Ingress (add to /etc/hosts):                          ║"
echo "║    echo \"${MINIKUBE_IP} api.mytutorial.local\" | sudo tee -a /etc/hosts  ║"
echo "║    Then open: http://api.mytutorial.local              ║"
echo "║                                                        ║"
echo "║  Minikube Dashboard:                                   ║"
echo "║    minikube dashboard                                  ║"
echo "║                                                        ║"
echo "╚══════════════════════════════════════════════════════════╝"