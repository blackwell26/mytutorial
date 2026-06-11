#!/bin/bash
# scripts/deploy-local.sh
set -euo pipefail

ENV=${1:-dev}
NAMESPACE=${NAMESPACE:-mytutorial}

echo "=== Deploying MyTutorial to Minikube (${ENV}) ==="
echo ""

# 1. Start minikube if not running
if ! minikube status 2>/dev/null | grep -q "Running"; then
  echo "--- Starting Minikube ---"
  minikube start --cpus 4 --memory 8192 --disk-size 20g
  echo ""
fi

# 2. Enable addons
echo "--- Enabling addons ---"
minikube addons enable ingress 2>/dev/null || true
minikube addons enable metrics-server 2>/dev/null || true
echo ""

# 3. Build images
echo "--- Building images ---"
eval $(minikube docker-env)
cd ../../backend
for svc in eureka-server auth-service grades-service notification-service api-gateway; do
  echo "  Building $svc..."
  docker build -f "$svc/Dockerfile" -t "mytutorial/$svc:latest" . 2>&1 | tail -1
done
cd ../"deploy local"
echo ""

# 4. Create namespace
echo "--- Creating namespace ---"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
echo ""

# 5. Deploy infrastructure
echo "--- Deploying infrastructure (Postgres, Redis, Kafka) ---"
kubectl apply -f infrastructure/ -n "${NAMESPACE}"
echo ""

# 6. Wait for infrastructure
echo "--- Waiting for infrastructure pods ---"
kubectl wait --for=condition=ready pod -l app=postgres -n "${NAMESPACE}" --timeout=120s 2>/dev/null || echo "  Postgres not ready yet (continuing...)"
kubectl wait --for=condition=ready pod -l app=redis -n "${NAMESPACE}" --timeout=60s 2>/dev/null || echo "  Redis not ready yet (continuing...)"
echo ""

# 7. Deploy application
echo "--- Deploying application (${ENV}) ---"
kustomize build "overlays/${ENV}" | kubectl apply -n "${NAMESPACE}" -f -
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
kubectl apply -f infrastructure/prometheus.yaml -n "${NAMESPACE}" 2>/dev/null || true
kubectl apply -f infrastructure/grafana.yaml -n "${NAMESPACE}" 2>/dev/null || true
kubectl apply -f infrastructure/elk.yaml -n "${NAMESPACE}" 2>/dev/null || true

# 10. Summary
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
echo "║    echo \"$(minikube ip) api.mytutorial.local\" | sudo tee -a /etc/hosts  ║"
echo "║    Then open: http://api.mytutorial.local              ║"
echo "║                                                        ║"
echo "║  Minikube Dashboard:                                   ║"
echo "║    minikube dashboard                                  ║"
echo "║                                                        ║"
echo "╚══════════════════════════════════════════════════════════╝"