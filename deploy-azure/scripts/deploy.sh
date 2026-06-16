#!/bin/bash
# scripts/deploy.sh
set -euo pipefail

ENV=${1:-dev}
NAMESPACE=${NAMESPACE:-mytutorial}

echo "=== Deploying MyTutorial to Azure Kubernetes Service ==="
echo "Environment: ${ENV}"
echo "Namespace:   ${NAMESPACE}"
echo ""

# Create namespace if not exists
kubectl get namespace "${NAMESPACE}" > /dev/null 2>&1 || \
  kubectl create namespace "${NAMESPACE}"

# Deploy infrastructure (Postgres, Redis, Kafka)
echo "--- Deploying infrastructure ---"
kubectl apply -f deploy-azure/infrastructure/ -n "${NAMESPACE}"

# Deploy monitoring
echo "--- Deploying monitoring ---"
kubectl apply -f deploy-azure/monitoring/ -n "${NAMESPACE}"

# Deploy application (via kustomize)
echo "--- Deploying application (${ENV}) ---"
kubectl apply -k "deploy-azure/overlays/${ENV}" --namespace "${NAMESPACE}"

echo ""
echo "=== Deployment complete ==="
echo ""

# Show Load Balancer IP once gateway is ready
echo "Waiting for api-gateway Load Balancer IP..."
for i in $(seq 1 30); do
  LB_IP=$(kubectl get svc api-gateway -n "${NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [ -n "$LB_IP" ]; then
    echo "  API Gateway available at: http://${LB_IP}"
    echo ""
    echo "  Test with: curl http://${LB_IP}/api/signin"
    break
  fi
  sleep 5
done

echo ""
echo "Watch pods: kubectl get pods -n ${NAMESPACE} -w"
