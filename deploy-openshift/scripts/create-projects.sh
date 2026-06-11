#!/bin/bash
# scripts/create-projects.sh
set -euo pipefail

CLUSTER_DOMAIN="${1:-apps.ocp.example.com}"

echo "=== Creating OpenShift projects for MyTutorial ==="
echo "Cluster domain: ${CLUSTER_DOMAIN}"
echo ""

for env in dev staging prod; do
  PROJECT="mytutorial-${env}"
  DISPLAY="MyTutorial - ${env}"
  echo "--- Creating ${PROJECT} ---"

  oc new-project "${PROJECT}" \
    --display-name="${DISPLAY}" \
    --description="MyTutorial Microservices - ${env} environment" \
    --skip-config-write=true 2>/dev/null || {
    echo "  Project ${PROJECT} already exists, switching..."
    oc project "${PROJECT}"
  }

  # Create service account + SCC
  echo "  Setting up SCC..."
  oc create sa mytutorial-sa -n "${PROJECT}" --dry-run=client -o yaml | oc apply -f -
  oc adm policy add-scc-to-user anyuid -z mytutorial-sa -n "${PROJECT}" 2>/dev/null || true

  # Create ImageStreams
  echo "  Creating ImageStreams..."
  for svc in eureka-server auth-service grades-service notification-service api-gateway; do
    oc apply -f - <<EOF 2>/dev/null || true
apiVersion: image.openshift.io/v1
kind: ImageStream
metadata:
  name: ${svc}
  namespace: ${PROJECT}
EOF
  done

  # Create limit range
  oc apply -f - <<EOF 2>/dev/null || true
apiVersion: v1
kind: LimitRange
metadata:
  name: mytutorial-limits
  namespace: ${PROJECT}
spec:
  limits:
    - max:
        cpu: "2"
        memory: "2Gi"
      default:
        cpu: "500m"
        memory: "512Mi"
      defaultRequest:
        cpu: "200m"
        memory: "256Mi"
      type: Container
EOF

  echo "  Project ${PROJECT} ready."
  echo ""
done

echo ""
echo "=== All projects created ==="
echo ""
echo "Project URLs:"
echo "  Dev:     https://api-mytutorial-dev.${CLUSTER_DOMAIN}"
echo "  Staging: https://api-mytutorial-staging.${CLUSTER_DOMAIN}"
echo "  Prod:    https://api-mytutorial-prod.${CLUSTER_DOMAIN}"