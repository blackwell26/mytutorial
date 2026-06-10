#!/bin/bash
set -euo pipefail

ENV=${1:-dev}
NAMESPACE=${NAMESPACE:-mytutorial}

echo "=== Deploying MyTutorial to Kubernetes ==="
echo "Environment: ${ENV}"
echo "Namespace:   ${NAMESPACE}"
echo ""

# Deploy infrastructure first
echo "--- Deploying infrastructure ---"
kubectl apply -f k8s/infrastructure/ -n "${NAMESPACE}"

# Deploy monitoring
echo "--- Deploying monitoring ---"
kubectl apply -f k8s/monitoring/ -n "${NAMESPACE}"

# Deploy application (via kustomize)
echo "--- Deploying application (${ENV}) ---"
kubectl apply -k "k8s/overlays/${ENV}" --namespace "${NAMESPACE}"

echo ""
echo "=== Deployment complete ==="
echo "Watch pods: kubectl get pods -n ${NAMESPACE} -w"