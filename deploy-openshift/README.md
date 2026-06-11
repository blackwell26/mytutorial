# Deploying & Managing Containerized Applications on Red Hat OpenShift

This is a self-contained deployment package for running the MyTutorial microservices stack on **Red Hat OpenShift** (OKD or OpenShift 4.x). It adapts the standard Kubernetes manifests for OpenShift's security model, routing, and developer workflows.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [OpenShift vs Vanilla Kubernetes](#2-openshift-vs-vanilla-kubernetes)
3. [Prerequisites & Tooling](#3-prerequisites--tooling)
4. [Building Images (OpenShift Builds)](#4-building-images-openshift-builds)
5. [Deploying with OpenShift Templates](#5-deploying-with-openshift-templates)
6. [Security Context Constraints (SCC)](#6-security-context-constraints-scc)
7. [Routes vs Ingress](#7-routes-vs-ingress)
8. [DeploymentConfig vs Deployment](#8-deploymentconfig-vs-deployment)
9. [Environment Overlays](#9-environment-overlays)
10. [CI/CD with OpenShift Pipelines](#10-cicd-with-openshift-pipelines)
11. [Observability](#11-observability)
12. [Managing the Cluster](#12-managing-the-cluster)
13. [Service Mesh Integration](#13-service-mesh-integration)
14. [Troubleshooting](#14-troubleshooting)

---

## 1. Architecture Overview

```
                           ┌─────────────────────┐
                           │  OpenShift Router   │
                           │  (HAProxy)          │
                           │   *.apps.ocp.example.com│
                           └──────────┬──────────┘
                                      │
                           ┌──────────▼──────────┐
                           │       Route         │
                           │  api-gateway-mytutorial │
                           │  mytutorial.apps.ocp│
                           └──────────┬──────────┘
                                      │
                    ┌─────────────────┼─────────────────┐
                    │                 │                  │
              ┌─────▼──────┐   ┌─────▼──────┐   ┌───────▼──────┐
              │ api-       │   │ auth-      │   │ grades-      │
              │ gateway    │   │ service    │   │ service      │
              │ :8080      │   │ :8081      │   │ :8082        │
              │ 2-10 pods  │   │ 2-10 pods  │   │ 2-10 pods    │
              │ DC/Deploy  │   │ DC/Deploy  │   │ DC/Deploy    │
              └─────┬──────┘   └─────┬──────┘   └───────┬──────┘
                    │                │                   │
              ┌─────▼──────┐        │             ┌─────▼──────┐
              │ eureka-    │        │             │ notifica-  │
              │ server     │        │             │ tion-svc   │
              │ :8761      │        │             │ :8083      │
              │ 1 pod      │        │             │ 1-5 pods   │
              └────────────┘        │             └─────┬──────┘
                                    │                   │
           ┌────────────────────────┼───────────────────┼──────────────────┐
           │                        │                   │                  │
     ┌─────▼──────┐          ┌──────▼──────┐     ┌──────▼──────┐   ┌──────▼──────┐
     │ PostgreSQL │          │ Redis       │     │ Kafka       │   │ Monitoring  │
     │ StatefulSet│          │ Deployment  │     │ StatefulSet │   │ Prometheus  │
     │ 5Gi PVC    │          │             │     │ 5Gi PVC     │   │ Grafana     │
     └────────────┘          └─────────────┘     └─────────────┘   │ ELK Stack   │
                                                                   └─────────────┘
```

## 2. OpenShift vs Vanilla Kubernetes

| Feature | Vanilla K8s | OpenShift | This Package |
|---------|-------------|-----------|--------------|
| **CLI** | `kubectl` | `oc` (same API, extra features) | Both work |
| **Project/NS** | Namespace | Project (Namespace + annotations) | `oc new-project mytutorial` |
| **Builds** | External CI/CD | Built-in S2I + BuildConfig + Pipeline | S2I + Dockerfile BuildConfig |
| **Image registry** | External | Internal OpenShift Registry | `image-registry.openshift-image-registry.svc:5000` |
| **Routing** | Ingress (NGINX) | Route (HAProxy) + Ingress | Route (primary) + Ingress (fallback) |
| **Deployment** | `Deployment` | `DeploymentConfig` (with triggers) | Both provided |
| **Security** | PodSecurityPolicy (deprecated) | SCC (Security Context Constraints) | SCC for `anyuid` + `nonroot` |
| **Secrets** | Secret | Secret + ServiceAccount tokens | Same + image pull secrets |
| **Monitoring** | Prometheus Operator (manual) | Built-in Cluster Monitoring + User Workload Monitoring | Prometheus + Grafana |
| **Auth** | RBAC | RBAC + OAuth + LDAP + SSO | OpenShift OAuth |
| **Console** | Dashboard (optional) | Built-in web console | `https://console-openshift-console.apps.ocp` |
| **Multi-tenancy** | Namespace | Project + NetworkPolicy + LimitRange | Project quotas |
| **Service Mesh** | Istio (manual) | OpenShift Service Mesh (managed) | Optional |
| **Serverless** | Knative (manual) | OpenShift Serverless (managed) | N/A |

### Key Decision: Keep Compatibility

This package uses **standard Kubernetes Deployments** (not DeploymentConfig) so manifests stay portable. It adds **OpenShift-specific files** as overlays:

```
deploy-openshift/
├── base/            ← Standard K8s (works everywhere)
├── overlays/        ← OpenShift-specific patches
│   └── openshift/   ← SCC, Routes, ImageStreams
├── infrastructure/  ← Same infra manifests
├── templates/       ← OpenShift Templates (.yaml)
└── scripts/         ← oc-based deploy scripts
```

---

## 3. Prerequisites & Tooling

### Required Tools

```bash
# ── OpenShift CLI (oc) ──
# Download from OpenShift Console or:
# Linux:
curl -LO https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-client-linux.tar.gz
tar xzf openshift-client-linux.tar.gz
sudo mv oc kubectl /usr/local/bin/

# macOS:
brew install openshift-cli

# Windows:
# Download from: https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/

# ── Verify ──
oc version
kubectl version --client

# ── Login ──
oc login https://api.ocp.example.com:6443 --username=admin --password=password

# Or via token (from Web Console → Copy Login Command)
oc login --token=sha256~xxxxx --server=https://api.ocp.example.com:6443
```

### Cluster Preparation

```bash
# Create project (OpenShift's namespace)
oc new-project mytutorial \
  --display-name="MyTutorial" \
  --description="MyTutorial Microservices Backend"

# Verify
oc project mytutorial

# Enable user-workload monitoring (for Prometheus metrics)
# This is done at cluster level — requires cluster-admin
# In OpenShift Console: Administration → Cluster Settings → Configuration → Cluster Monitoring
# Enable "User Workload Monitoring"
```

### OpenShift-Specific Concepts

| Concept | What It Is | How We Use It |
|---------|-----------|---------------|
| **Project** | Namespace with annotations | `mytutorial` project |
| **Route** | External HTTP/HTTPS endpoint | Expose api-gateway |
| **SCC** | Security constraints | Allow Java/JRE to run as non-root |
| **ImageStream** | Abstract image reference | Track built images across envs |
| **BuildConfig** | Build definition | S2I or Docker build in-cluster |
| **DeploymentConfig** | Deployment with triggers | Auto-rollout on image change |
| **Pipeline** | Tekton-based CI/CD | Build → Push → Deploy |
| **Operator** | Kubernetes operator | Install middleware operators |

---

## 4. Building Images (OpenShift Builds)

### 4.1 Option A: Push to OpenShift Internal Registry

```bash
# Login to OpenShift registry
REGISTRY=$(oc get route default-route -n openshift-image-registry --template='{{ .spec.host }}')
podman login -u $(oc whoami) -p $(oc whoami -t) $REGISTRY

# Build and push images
PROJECT=$(oc project -q)
for svc in eureka-server auth-service grades-service notification-service api-gateway; do
  cd backend
  podman build -f "$svc/Dockerfile" -t "$REGISTRY/$PROJECT/$svc:latest" .
  podman push "$REGISTRY/$PROJECT/$svc:latest"
  cd ..
done
```

### 4.2 Option B: BuildConfig with Docker Strategy (In-Cluster Builds)

OpenShift can build images directly from your Git repo using **Docker strategy**:

```yaml
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata:
  name: auth-service
  labels:
    app: auth-service
spec:
  source:
    git:
      uri: https://github.com/your-org/mytutorial.git
      ref: main
    contextDir: backend
  strategy:
    dockerStrategy:
      dockerfilePath: auth-service/Dockerfile
  output:
    to:
      kind: ImageStreamTag
      name: auth-service:latest
  triggers:
    - type: GitHub
      github:
        secretReference:
          name: github-webhook-secret
    - type: ConfigChange
    - type: ImageChange
```

```bash
# Create BuildConfig
oc apply -f templates/buildconfigs.yaml -n mytutorial

# Start builds
for bc in eureka-server auth-service grades-service notification-service api-gateway; do
  oc start-build $bc -n mytutorial
done

# Watch builds
oc get builds -n mytutorial -w
```

### 4.3 Option C: Source-to-Image (S2I) for Java

S2I injects the source into a builder image without needing a Dockerfile:

```bash
# For Spring Boot apps with Maven wrapper:
oc new-build java:21 \
  --name=auth-service \
  --binary=false \
  --context-dir=backend/auth-service

oc start-build auth-service \
  --from-dir=./backend/auth-service \
  --follow
```

### 4.4 ImageStreams (Abstract Image References)

ImageStreams decouple the image location from the deployment:

```yaml
apiVersion: image.openshift.io/v1
kind: ImageStream
metadata:
  name: auth-service
spec:
  lookupPolicy:
    local: true
  tags:
    - name: latest
      from:
        kind: DockerImage
        name: image-registry.openshift-image-registry.svc:5000/mytutorial/auth-service:latest
      importPolicy:
        scheduled: true
```

```bash
# Create ImageStreams
for svc in eureka-server auth-service grades-service notification-service api-gateway; do
  oc apply -f - <<EOF
apiVersion: image.openshift.io/v1
kind: ImageStream
metadata:
  name: $svc
EOF
done
```

### 4.5 Build Script

```bash
#!/bin/bash
# scripts/build-openshift.sh
set -euo pipefail

PROJECT="${1:-mytutorial}"
REGISTRY=$(oc get route default-route -n openshift-image-registry --template='{{ .spec.host }}' 2>/dev/null || echo "image-registry.openshift-image-registry.svc:5000")
SERVICES=("eureka-server" "auth-service" "grades-service" "notification-service" "api-gateway")

echo "=== Building & pushing images to OpenShift registry ==="
echo "Project:  ${PROJECT}"
echo "Registry: ${REGISTRY}"
echo ""

# Login to registry
podman login -u $(oc whoami) -p $(oc whoami -t) "$REGISTRY" 2>/dev/null || true

# Build and push each service
for svc in "${SERVICES[@]}"; do
  echo "--- Building ${svc} ---"
  cd ../../backend
  podman build \
    -f "${svc}/Dockerfile" \
    -t "${REGISTRY}/${PROJECT}/${svc}:latest" \
    -t "${REGISTRY}/${PROJECT}/${svc}:$(git rev-parse --short HEAD)" \
    . 2>&1 | tail -3
  echo "--- Pushing ${svc} ---"
  podman push "${REGISTRY}/${PROJECT}/${svc}:latest" 2>&1 | tail -1
  podman push "${REGISTRY}/${PROJECT}/${svc}:$(git rev-parse --short HEAD)" 2>&1 | tail -1
  cd ../"deploy-openshift"
  echo ""
done

echo "=== Build complete ==="
```

---

## 5. Deploying with OpenShift Templates

### 5.1 OpenShift Templates

Templates parameterize your deployment so users can deploy from the OpenShift console with a form:

```yaml
# templates/mytutorial.yaml — Full application template
apiVersion: template.openshift.io/v1
kind: Template
metadata:
  name: mytutorial
  annotations:
    description: "MyTutorial Microservices Stack"
    tags: "spring-boot,java,microservices"
    iconClass: "icon-spring"
objects:
  # ── Infrastructure ──
  - apiVersion: apps/v1
    kind: StatefulSet
    metadata:
      name: postgres
      labels:
        app: postgres
    spec:
      serviceName: postgres
      replicas: 1
      selector:
        matchLabels:
          app: postgres
      template:
        metadata:
          labels:
            app: postgres
        spec:
          containers:
            - name: postgres
              image: postgres:16-alpine
              ports:
                - containerPort: 5432
              env:
                - name: POSTGRES_DB
                  value: postgres
                - name: POSTGRES_USER
                  value: postgres
                - name: POSTGRES_PASSWORD
                  value: ${DB_PASSWORD}
              volumeMounts:
                - name: postgres-data
                  mountPath: /var/lib/postgresql/data
      volumeClaimTemplates:
        - metadata:
            name: postgres-data
          spec:
            accessModes: ["ReadWriteOnce"]
            resources:
              requests:
                storage: ${DB_STORAGE_SIZE}
  - apiVersion: v1
    kind: Service
    metadata:
      name: postgres
    spec:
      ports:
        - port: 5432
      selector:
        app: postgres

  # ── Application Services (repeated pattern per service) ──
  - apiVersion: image.openshift.io/v1
    kind: ImageStream
    metadata:
      name: auth-service
  - apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: auth-service
    spec:
      replicas: ${{AUTH_REPLICAS}}
      selector:
        matchLabels:
          app: auth-service
      template:
        metadata:
          labels:
            app: auth-service
        spec:
          serviceAccountName: mytutorial-sa
          containers:
            - name: auth-service
              image: ${REGISTRY}/${PROJECT}/auth-service:${IMAGE_TAG}
              ports:
                - containerPort: 8081
              env:
                - name: SPRING_PROFILES_ACTIVE
                  value: "openshift"
                - name: SPRING_DATASOURCE_URL
                  value: "jdbc:postgresql://postgres:5432/postgres"
                - name: SPRING_DATASOURCE_USERNAME
                  value: postgres
                - name: SPRING_DATASOURCE_PASSWORD
                  value: ${DB_PASSWORD}
                - name: SPRING_DATA_REDIS_HOST
                  value: redis
                - name: SPRING_KAFKA_BOOTSTRAP_SERVERS
                  value: kafka:9092
                - name: EUREKA_CLIENT_SERVICEURL_DEFAULTZONE
                  value: http://eureka-server:8761/eureka/
              resources:
                requests:
                  cpu: ${AUTH_CPU_REQUEST}
                  memory: ${AUTH_MEM_REQUEST}
                limits:
                  cpu: ${AUTH_CPU_LIMIT}
                  memory: ${AUTH_MEM_LIMIT}
  - apiVersion: v1
    kind: Service
    metadata:
      name: auth-service
    spec:
      ports:
        - port: 8081
      selector:
        app: auth-service
  - apiVersion: route.openshift.io/v1
    kind: Route
    metadata:
      name: auth-service
    spec:
      to:
        kind: Service
        name: auth-service
      port:
        targetPort: 8081
      tls:
        termination: edge
        insecureEdgeTerminationPolicy: Redirect

  # ── API Gateway + Route ──
  - apiVersion: route.openshift.io/v1
    kind: Route
    metadata:
      name: api-gateway
      annotations:
        haproxy.router.openshift.io/rewrite-target: /
    spec:
      host: ${APPLICATION_DOMAIN}
      to:
        kind: Service
        name: api-gateway
      port:
        targetPort: 8080
      tls:
        termination: edge
        insecureEdgeTerminationPolicy: Redirect

parameters:
  - name: APPLICATION_DOMAIN
    description: Public domain for the API gateway
    value: api-mytutorial.apps.ocp.example.com
  - name: REGISTRY
    description: Container registry URL
    value: image-registry.openshift-image-registry.svc:5000
  - name: PROJECT
    description: OpenShift project name
    value: mytutorial
  - name: IMAGE_TAG
    description: Image tag to deploy
    value: latest
  - name: DB_PASSWORD
    description: PostgreSQL password
    generate: expression
    from: "[a-zA-Z0-9]{16}"
  - name: DB_STORAGE_SIZE
    description: PostgreSQL storage size
    value: "5Gi"
  - name: AUTH_REPLICAS
    description: Auth service replicas
    value: "2"
  - name: AUTH_CPU_REQUEST
    value: "300m"
  - name: AUTH_MEM_REQUEST
    value: "512Mi"
  - name: AUTH_CPU_LIMIT
    value: "1"
  - name: AUTH_MEM_LIMIT
    value: "1Gi"
  # Repeat for each service...
```

### 5.2 Deploy from Template

```bash
# Using CLI:
oc process -f templates/mytutorial.yaml \
  -p APPLICATION_DOMAIN=api-mytutorial.apps.ocp.example.com \
  -p DB_PASSWORD=supersecret | oc apply -f -

# Or from OpenShift Web Console:
# 1. Click "+Add" → "Import YAML / JSON"
# 2. Paste the template YAML
# 3. Fill in the parameters form
# 4. Click "Create"
```

### 5.3 Quick Deploy Script

```bash
#!/bin/bash
# scripts/deploy-openshift.sh
set -euo pipefail

PROJECT="${1:-mytutorial}"
ENV="${2:-dev}"
NAMESPACE="${PROJECT}-${ENV}"

echo "=== Deploying MyTutorial to OpenShift (${ENV}) ==="
echo ""

# 1. Create project
echo "--- Creating project ${NAMESPACE} ---"
oc new-project "${NAMESPACE}" --skip-config-write=true 2>/dev/null || oc project "${NAMESPACE}"
echo ""

# 2. Create service account with SCC
echo "--- Creating service account ---"
oc create sa mytutorial-sa -n "${NAMESPACE}" --dry-run=client -o yaml | oc apply -f -
oc adm policy add-scc-to-user anyuid -z mytutorial-sa -n "${NAMESPACE}"
echo ""

# 3. Apply infrastructure
echo "--- Deploying infrastructure ---"
kubectl apply -f infrastructure/ -n "${NAMESPACE}"
echo ""

# 4. Wait for infra
echo "--- Waiting for infrastructure ---"
kubectl wait --for=condition=ready pod -l app=postgres -n "${NAMESPACE}" --timeout=120s 2>/dev/null || true
kubectl wait --for=condition=ready pod -l app=redis -n "${NAMESPACE}" --timeout=60s 2>/dev/null || true
echo ""

# 5. Apply OpenShift-specific overlays
echo "--- Applying OpenShift overlays ---"
kustomize build "overlays/${ENV}" | kubectl apply -n "${NAMESPACE}" -f -
echo ""

# 6. Create Routes
echo "--- Creating Routes ---"
oc expose svc/api-gateway --hostname="api-${NAMESPACE}.apps.ocp.example.com" -n "${NAMESPACE}" 2>/dev/null || true
for svc in auth-service eureka-server; do
  oc expose svc/$svc -n "${NAMESPACE}" 2>/dev/null || true
done
echo ""

# 7. Wait for application
echo "--- Waiting for application ---"
for svc in eureka-server auth-service grades-service notification-service api-gateway; do
  kubectl rollout status "deployment/$svc" -n "${NAMESPACE}" --timeout=180s 2>/dev/null || echo "  $svc timed out"
done
echo ""

# 8. Summary
echo ""
echo "=== Deployment complete ==="
echo ""
echo "Access the application:"
echo "  Route:  https://api-${NAMESPACE}.apps.ocp.example.com"
echo "  Console: https://console-openshift-console.apps.ocp.example.com"
echo ""
echo "Verify:"
echo "  curl -k https://api-${NAMESPACE}.apps.ocp.example.com/actuator/health"
```

---

## 6. Security Context Constraints (SCC)

### 6.1 The Problem

OpenShift **does not run containers as root** by default. The JRE base image (`eclipse-temurin:21-jre-alpine`) runs with a non-root `uid=101`, which can cause issues with:
- Binding to ports below 1024 (not an issue — services use 8080+)
- Writing to volumes mounted by root-owned PVCs
- Writing to log directories

### 6.2 SCC Configuration

Apply the `anyuid` SCC to allow JRE containers to run with their default UID:

```bash
# Option A: Apply to service account (preferred)
oc adm policy add-scc-to-user anyuid -z mytutorial-sa -n mytutorial

# Option B: Apply restricted with custom UID
oc adm policy add-scc-to-user nonroot -z mytutorial-sa -n mytutorial

# Option C: Verify which SCC applies
oc describe pod auth-service-xxxxx -n mytutorial | grep openshift.io/scc
```

### 6.3 SCC Manifest

```yaml
# base/scc.yaml
apiVersion: security.openshift.io/v1
kind: SecurityContextConstraints
metadata:
  name: mytutorial-scc
allowPrivilegedContainer: false
allowPrivilegeEscalation: false
allowedCapabilities: []
defaultAddCapabilities: []
requiredDropCapabilities:
  - ALL
runAsUser:
  type: MustRunAsNonRoot
seLinuxContext:
  type: MustRunAs
fsGroup:
  type: MustRunAs
  ranges:
    - min: 1
      max: 65535
supplementalGroups:
  type: MustRunAs
  ranges:
    - min: 1
      max: 65535
volumes:
  - configMap
  - secret
  - persistentVolumeClaim
  - emptyDir
users:
  - system:serviceaccount:mytutorial:mytutorial-sa
```

### 6.4 Service Account & SCC Setup

```yaml
# base/serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: mytutorial-sa
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: mytutorial-sa-anyuid
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:openshift:scc:anyuid
subjects:
  - kind: ServiceAccount
    name: mytutorial-sa
```

```bash
# Apply
kubectl apply -f base/serviceaccount.yaml -n mytutorial
```

### 6.5 Running Without SCC Changes

If you cannot modify SCCs (restricted cluster), set `securityContext` in the Deployments:

```yaml
# In each Deployment spec.template.spec:
securityContext:
  runAsUser: 1001
  runAsNonRoot: true
  fsGroup: 1001
containers:
  - name: auth-service
    securityContext:
      capabilities:
        drop: ["ALL"]
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
    env:
      - name: LOGGING_FILE_PATH
        value: /tmp/logs  # Write logs to tmpfs instead of filesystem
```

### 6.6 Spring Boot for Restricted SCC

Create an `application-openshift.yml` profile that writes logs to `/tmp`:

```yaml
spring:
  application:
    name: auth-service

logging:
  file:
    path: /tmp/logs

server:
  port: 8081
```

This is already handled — ports are 8080+, which is non-privileged.

---

## 7. Routes vs Ingress

### 7.1 OpenShift Routes (Primary)

Routes are OpenShift's native way to expose services externally. They use the **OpenShift Router** (HAProxy):

```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: api-gateway
  annotations:
    # Rewrite target (remove path prefix)
    haproxy.router.openshift.io/rewrite-target: /
    # Rate limiting (req/s per IP)
    haproxy.router.openshift.io/rate-limit-connections: "100"
    # Timeouts
    haproxy.router.openshift.io/timeout: 30s
spec:
  host: api-mytutorial.apps.ocp.example.com
  path: /
  to:
    kind: Service
    name: api-gateway
    weight: 100
  port:
    targetPort: 8080
  tls:
    termination: edge           # TLS terminates at router
    insecureEdgeTerminationPolicy: Redirect  # HTTP → HTTPS
  wildcardPolicy: None
```

```bash
# Create routes
oc create route edge api-gateway \
  --service=api-gateway \
  --port=8080 \
  --hostname=api-mytutorial.apps.ocp.example.com \
  --insecure-policy=Redirect \
  -n mytutorial

# List routes
oc get routes -n mytutorial

# Get URL
oc get route api-gateway -n mytutorial --template='https://{{ .spec.host }}{{ .spec.path }}'
```

### 7.2 Route Types

| Type | TLS Termination | Use Case |
|------|----------------|----------|
| **Edge** | Router | External users → HTTPS, internal HTTP (simplest) |
| **Passthrough** | Backend | App handles TLS itself (e.g., for mTLS) |
| **Re-encrypt** | Router + Backend | Router verifies with backend via separate cert |
| **Non-TLS** | None | HTTP only (development) |

### 7.3 Ingress Compatibility

OpenShift also supports standard Kubernetes Ingress, which the router converts:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: api-gateway
  annotations:
    route.openshift.io/termination: edge  # Makes Ingress create a Route
spec:
  ingressClassName: openshift-default
  rules:
    - host: api-mytutorial.apps.ocp.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: api-gateway
                port:
                  number: 8080
```

Both Route and Ingress are provided in this package.

### 7.4 Routes for All Services

```yaml
# base/routes.yaml
apiVersion: route.openshift.io/v1
kind: List
items:
  - apiVersion: route.openshift.io/v1
    kind: Route
    metadata:
      name: api-gateway
      annotations:
        haproxy.router.openshift.io/rewrite-target: /
    spec:
      to:
        kind: Service
        name: api-gateway
      port:
        targetPort: 8080
      tls:
        termination: edge
        insecureEdgeTerminationPolicy: Redirect

  - apiVersion: route.openshift.io/v1
    kind: Route
    metadata:
      name: eureka-server
    spec:
      to:
        kind: Service
        name: eureka-server
      port:
        targetPort: 8761
      tls:
        termination: edge

  - apiVersion: route.openshift.io/v1
    kind: Route
    metadata:
      name: auth-service
    spec:
      to:
        kind: Service
        name: auth-service
      port:
        targetPort: 8081

  - apiVersion: route.openshift.io/v1
    kind: Route
    metadata:
      name: prometheus
    spec:
      to:
        kind: Service
        name: prometheus
      port:
        targetPort: 9090

  - apiVersion: route.openshift.io/v1
    kind: Route
    metadata:
      name: grafana
    spec:
      to:
        kind: Service
        name: grafana
      port:
        targetPort: 3000
```

---

## 8. DeploymentConfig vs Deployment

### 8.1 When to Use Which

| Feature | Deployment | DeploymentConfig (DC) |
|---------|-----------|----------------------|
| **Standard K8s** | Yes | OpenShift-specific |
| **Rolling updates** | Yes | Yes |
| **Image change triggers** | No (manual) | Yes (auto-rollout on new image) |
| **Config change triggers** | No (manual restart) | Yes |
| **Rollback** | `kubectl rollout undo` | `oc rollback` (simpler) |
| **Lifecycle hooks** | No | Pre/Post deployment hooks |
| **Portability** | Any K8s cluster | OpenShift only |

### 8.2 This Package Uses Deployments

For maximum portability, the base manifests use **standard Deployments**. If you want DeploymentConfig, use the `base/deploymentconfigs.yaml` overlay:

```yaml
apiVersion: apps.openshift.io/v1
kind: DeploymentConfig
metadata:
  name: auth-service
  labels:
    app: auth-service
spec:
  replicas: 2
  selector:
    app: auth-service
  triggers:
    - type: ConfigChange
    - type: ImageChange
      imageChangeParams:
        automatic: true
        containerNames:
          - auth-service
        from:
          kind: ImageStreamTag
          name: auth-service:latest
  template:
    metadata:
      labels:
        app: auth-service
    spec:
      serviceAccountName: mytutorial-sa
      containers:
        - name: auth-service
          image: mytutorial/auth-service:latest
          ports:
            - containerPort: 8081
          envFrom:
            - configMapRef:
                name: mytutorial-shared
            - configMapRef:
                name: auth-service-config
          livenessProbe:
            httpGet:
              path: /actuator/health/liveness
              port: 8081
            initialDelaySeconds: 60
            periodSeconds: 15
          readinessProbe:
            httpGet:
              path: /actuator/health/readiness
              port: 8081
            initialDelaySeconds: 30
            periodSeconds: 10
          resources:
            requests:
              cpu: "300m"
              memory: "512Mi"
            limits:
              cpu: "1"
              memory: "1Gi"
```

### 8.3 Deployment Triggers

The power of DeploymentConfig is automatic deployment on image change:

```yaml
triggers:
  - type: ConfigChange          # Trigger on ConfigMap/Secret change
  - type: ImageChange           # Trigger on ImageStreamTag change
    imageChangeParams:
      automatic: true
      containerNames:
        - auth-service
      from:
        kind: ImageStreamTag
        name: auth-service:latest
```

When you push a new image to the ImageStream, OpenShift automatically:
1. Detects the change
2. Starts a new rollout
3. Monitors the new pods for health
4. Automatically rolls back if health checks fail

---

## 9. Environment Overlays

### 9.1 Dev

```yaml
# overlays/dev/kustomization.yaml
# - 1 replica
# - Small resource requests
# - Non-TLS routes
# - Debug logging enabled
```

```bash
oc project mytutorial-dev
kustomize build overlays/dev | oc apply -f -
```

### 9.2 Staging

```yaml
# overlays/staging/kustomization.yaml
# - 2 replicas
# - Edge TLS routes
# - Auto-scaling enabled
# - Staging domain names
```

```bash
oc project mytutorial-staging
kustomize build overlays/staging | oc apply -f -
```

### 9.3 Production

```yaml
# overlays/prod/kustomization.yaml
# - 3 replicas
# - Full resource limits
# - Edge TLS with production certificates
# - HPA 3-15 replicas
# - PDB enforced
# - Pod anti-affinity for HA
```

```bash
oc project mytutorial-prod
kustomize build overlays/prod | oc apply -f -
```

### 9.4 Shared Kustomize Overlay

```yaml
# overlays/openshift/kustomization.yaml
# Shared patches applied to all OpenShift environments
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: mytutorial

resources:
  - ../../base
  - scc.yaml
  - routes.yaml
  - serviceaccount.yaml
  - deploymentconfigs.yaml

patches:
  # Set imagePullPolicy for internal registry
  - patch: |-
      - op: replace
        path: /spec/template/spec/containers/0/imagePullPolicy
        value: Always
    target:
      kind: Deployment
  # Add service account to all deployments
  - patch: |-
      - op: add
        path: /spec/template/spec/serviceAccountName
        value: mytutorial-sa
    target:
      kind: Deployment
```

---

## 10. CI/CD with OpenShift Pipelines

### 10.1 OpenShift Pipelines (Tekton)

OpenShift Pipelines is a Kubernetes-native CI/CD system based on Tekton:

```yaml
# pipelines/auth-service-pipeline.yaml
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: auth-service-pipeline
spec:
  params:
    - name: repo-url
      description: Git repository URL
      default: https://github.com/your-org/mytutorial.git
    - name: revision
      description: Git revision to build
      default: main
    - name: image-tag
      description: Image tag
      default: latest
  tasks:
    - name: test
      taskSpec:
        steps:
          - name: mvn-test
            image: maven:3.9-eclipse-temurin-21
            workingDir: $(workspaces.source.path)/backend
            script: mvn -B test -q
    - name: build-image
      taskRef:
        name: buildah
      params:
        - name: IMAGE
          value: image-registry.openshift-image-registry.svc:5000/mytutorial/auth-service:$(params.image-tag)
        - name: DOCKERFILE
          value: ./backend/auth-service/Dockerfile
      workspaces:
        - name: source
          workspace: shared-workspace
    - name: deploy
      taskSpec:
        steps:
          - name: oc-rollout
            image: image-registry.openshift-image-registry.svc:5000/openshift/cli:latest
            script: |
              oc rollout restart deployment/auth-service -n mytutorial
              oc rollout status deployment/auth-service -n mytutorial --timeout=300s
  workspaces:
    - name: shared-workspace
```

```bash
# Install OpenShift Pipelines Operator
# From OpenShift Console: Operators → OperatorHub → "OpenShift Pipelines"

# Apply the pipeline
oc apply -f pipelines/auth-service-pipeline.yaml -n mytutorial

# Create PipelineRun
tkn pipeline start auth-service-pipeline \
  -p revision=main \
  -p image-tag=$(git rev-parse --short HEAD) \
  -w name=shared-workspace,claimName=pvc-workspace \
  --use-param-defaults
```

### 10.2 GitHub Actions (Alternative)

OpenShift can also be deployed via GitHub Actions (same as any K8s cluster):

```yaml
name: Deploy to OpenShift

on:
  push:
    branches: [main]

env:
  OPENSHIFT_SERVER: ${{ secrets.OPENSHIFT_SERVER }}
  OPENSHIFT_TOKEN: ${{ secrets.OPENSHIFT_TOKEN }}
  PROJECT: mytutorial

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with:
          java-version: '21'
          distribution: 'temurin'
          cache: maven
      - run: mvn -B test -q
        working-directory: backend

      - name: Login to OpenShift
        uses: redhat-actions/oc-login@v1
        with:
          openshift_server_url: ${{ env.OPENSHIFT_SERVER }}
          openshift_token: ${{ env.OPENSHIFT_TOKEN }}
          namespace: ${{ env.PROJECT }}

      - name: Build and push
        run: |
          REGISTRY=$(oc get route default-route -n openshift-image-registry --template='{{ .spec.host }}')
          podman login -u $(oc whoami) -p $(oc whoami -t) $REGISTRY
          for svc in eureka-server auth-service grades-service notification-service api-gateway; do
            podman build -f backend/$svc/Dockerfile \
              -t $REGISTRY/$PROJECT/$svc:${{ github.sha }} \
              -t $REGISTRY/$PROJECT/$svc:latest ./backend
            podman push $REGISTRY/$PROJECT/$svc:${{ github.sha }}
            podman push $REGISTRY/$PROJECT/$svc:latest
          done

      - name: Deploy
        run: |
          cd deploy-openshift
          kustomize build overlays/prod | oc apply -f -
          for svc in eureka-server auth-service grades-service notification-service api-gateway; do
            oc rollout status deployment/$svc --timeout=300s
          done
```

---

## 11. Observability

### 11.1 OpenShift Monitoring Stack

OpenShift ships with a built-in monitoring stack based on Prometheus:

```bash
# Enable monitoring for user-defined projects
# As cluster-admin:
oc apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF

# Wait for monitoring stack to reconfigure
```

```yaml
# ServiceMonitor — tells OpenShift monitoring to scrape your services
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: mytutorial-monitor
  labels:
    release: k8s
spec:
  selector:
    matchLabels:
      tier: backend
  endpoints:
    - port: http
      path: /actuator/prometheus
      interval: 15s
  namespaceSelector:
    matchNames:
      - mytutorial
```

```bash
# Apply ServiceMonitor
oc apply -f base/servicemonitor.yaml -n mytutorial

# Access metrics in OpenShift Console
# Observe → Metrics → Query: jvm_memory_used_bytes
```

### 11.2 OpenShift Logging (Loki)

Deploy the OpenShift Logging Operator for log aggregation:

```bash
# Install Red Hat OpenShift Logging Operator from OperatorHub
# Then create a LokiStack instance
```

### 11.3 OpenShift Web Console

```bash
# Built-in dashboards:
# Home → Overview (cluster health)
# Developer → Topology (application graph)
# Observe → Metrics (PromQL queries)
# Observe → Alerts (alerting rules)
# Observe → Dashboards (pre-built dashboards)
```

### 11.4 OpenShift Cost Management

```bash
# Install OpenShift Cost Management Operator
# Provides visibility into resource usage per project, deployment, and pod
```

### 11.5 Application Monitoring (Grafana)

The included Grafana deployment works on OpenShift:

```bash
# Deploy
kubectl apply -f infrastructure/grafana.yaml -n mytutorial

# Create route
oc create route edge grafana --service=grafana --port=3000 -n mytutorial

# Access: https://grafana-mytutorial.apps.ocp.example.com (admin/admin)
```

---

## 12. Managing the Cluster

### 12.1 OpenShift CLI (oc) vs kubectl

```bash
# Both work — oc has additional commands:

# Projects
oc new-project mytutorial
oc project mytutorial
oc get projects

# Status
oc status                    # Overview of project resources
oc get all                   # All resources in the project

# Routes
oc expose svc/api-gateway    # Create route
oc get routes
oc delete route api-gateway

# Builds
oc get builds
oc logs build/auth-service-1

# ImageStreams
oc get imagestreams
oc describe is auth-service

# DeploymentConfig
oc rollout latest dc/auth-service
oc rollback dc/auth-service --to-version=2

# Users and permissions
oc describe policyBindings :default
oc policy add-role-to-user view -z mytutorial-sa
```

### 12.2 OpenShift Web Console

The OpenShift web console provides:

- **Developer Console** — Application-centric view: Topology, Builds, Routes, Monitoring
- **Administrator Console** — Cluster management: Nodes, Operators, Storage, Monitoring
- **+Add** — Deploy from Git, Container images, Dockerfile, Templates, YAML

### 12.3 Pod Placement & Topology

```yaml
# OpenShift uses standard K8s scheduling with additional features:
# - NodeSelector
# - Pod affinity/anti-affinity
# - Taints/Tolerations
# - Descheduler (for balancing)

# Example: spread pods across nodes for HA
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchExpressions:
              - key: app
                operator: In
                values:
                  - auth-service
          topologyKey: kubernetes.io/hostname
```

### 12.4 Resource Management

```yaml
# LimitRange — enforce min/max resource usage per pod
apiVersion: v1
kind: LimitRange
metadata:
  name: mytutorial-limits
spec:
  limits:
    - max:
        cpu: "2"
        memory: "2Gi"
      min:
        cpu: "100m"
        memory: "128Mi"
      default:
        cpu: "500m"
        memory: "512Mi"
      defaultRequest:
        cpu: "200m"
        memory: "256Mi"
      type: Container
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: mytutorial-quota
spec:
  hard:
    requests.cpu: "8"
    requests.memory: "16Gi"
    limits.cpu: "16"
    limits.memory: "32Gi"
    persistentvolumeclaims: "5"
    pods: "50"
```

### 12.5 Cluster Upgrades

```bash
# OpenShift manages its own upgrades via the Cluster Version Operator
# As cluster-admin:
oc adm upgrade --to-latest
# or:
oc adm upgrade --to=4.16.0

# Monitor upgrade
oc adm upgrade --watch
```

---

## 13. Service Mesh Integration

### 13.1 Install OpenShift Service Mesh

```bash
# Install from OperatorHub:
# - Red Hat OpenShift Service Mesh Operator (installs Istio, Kiali, Jaeger)
# - Red Hat OpenShift distributed tracing platform (Jaeger)
# - Kiali Operator (observability console)

# Create ServiceMeshControlPlane
oc apply -f - <<'EOF'
apiVersion: maistra.io/v2
kind: ServiceMeshControlPlane
metadata:
  name: basic
  namespace: istio-system
spec:
  version: v2.6
  tracing:
    type: Jaeger
    sampling: 10000
  policy:
    type: Istiod
  addons:
    grafana:
      enabled: true
    kiali:
      enabled: true
    prometheus:
      enabled: true
EOF
```

### 13.2 Add Applications to the Mesh

```yaml
# Create ServiceMeshMemberRoll to include mytutorial project
apiVersion: maistra.io/v1
kind: ServiceMeshMemberRoll
metadata:
  name: default
  namespace: istio-system
spec:
  members:
    - mytutorial
```

Annotate deployments for sidecar injection:

```yaml
# In each Deployment template.metadata:
annotations:
  sidecar.istio.io/inject: "true"
```

### 13.3 Benefits of Service Mesh

| Feature | Benefit for MyTutorial |
|---------|----------------------|
| **Mutual TLS** | Encrypted pod-to-pod communication |
| **Traffic splitting** | Canary deployments (e.g., 10% → v2, 90% → v1) |
| **Circuit breaking** | Prevent cascading failures |
| **Retries & timeouts** | Resilient inter-service calls |
| **Distributed tracing** | Jaeger integration (replaces X-Ray) |
| **Telemetry** | Request rate, latency, error rate per service |
| **Access control** | Service-level RBAC with Kubernetes API |
| **Kiali dashboard** | Service graph visualization |

---

## 14. Troubleshooting

### 14.1 OpenShift-Specific Issues

| Error | Cause | Fix |
|-------|-------|-----|
| `unable to start container: Error: container has runAsNonRoot and image will run as root` | Image runs as root, SCC rejects it | Add `anyuid` SCC: `oc adm policy add-scc-to-user anyuid -z mytutorial-sa` |
| `CrashLoopBackOff: permission denied` | Cannot write to mounted volume | Set `fsGroup: 1001` in Deployment securityContext |
| `ImageStreamTag not found` | Image not imported yet | Check `oc get is` and `oc import-image` |
| `Build failed: context deadline exceeded` | Build takes too long | Increase timeout in BuildConfig |
| `Route not accepting traffic` | Router not configured or backend unhealthy | Check `oc get route` and pod readiness probes |
| `503 Service Unavailable` | No healthy backends | Check pod logs and readiness probes |
| `forbidden: try to scale down past minimum PDB` | PDB prevents scaling | Check `oc get pdb` |
| `could not find any route for the host` | Route hostname mismatch | Verify DNS → Route → Service chain |

### 14.2 Pod Won't Start

```bash
# Check events
oc get events -n mytutorial --sort-by='.lastTimestamp'

# Check pod details (especially SCC section)
oc describe pod auth-service-xxxxx -n mytutorial

# Check SCC assigned:
oc describe pod auth-service-xxxxx -n mytutorial | grep openshift.io/scc

# Check service account permissions
oc describe sa mytutorial-sa -n mytutorial
oc describe rolebinding mytutorial-sa-anyuid -n mytutorial
```

### 14.3 Build Issues

```bash
# View build logs
oc logs build/auth-service-1 -n mytutorial

# Cancel stuck build
oc cancel-build auth-service-1 -n mytutorial

# Re-run build
oc start-build auth-service --from-dir=./backend/auth-service --follow -n mytutorial

# List builds
oc get builds -n mytutorial
```

### 14.4 Route Issues

```bash
# Check route status
oc describe route api-gateway -n mytutorial

# Test route from inside the cluster (skips router)
oc run curl-test --image=curlimages/curl --rm -it -n mytutorial -- \
  curl -sv http://api-gateway:80/actuator/health

# Check if router pods are healthy
oc get pods -n openshift-ingress

# Check router logs
oc logs deployment/router-default -n openshift-ingress --tail=50
```

### 14.5 Image Pull Issues

```bash
# Check if ImageStream exists
oc get imagestream auth-service -n mytutorial

# Check tags
oc describe is auth-service -n mytutorial

# Force image import
oc import-image auth-service:latest --from=image-registry.openshift-image-registry.svc:5000/mytutorial/auth-service:latest --confirm -n mytutorial

# Check service account has pull access
oc secrets link mytutorial-sa $(oc get sa mytutorial-sa -n mytutorial -o jsonpath='{.imagePullSecrets[0].name}') --for=pull -n mytutorial
```

### 14.6 Quick Diagnostic Commands

```bash
# ═══════════════════════════════════════════════════
# OPENSHIFT STATUS
# ═══════════════════════════════════════════════════
oc whoami
oc project
oc status

# ═══════════════════════════════════════════════════
# APPLICATION STATUS
# ═══════════════════════════════════════════════════
oc get all -n mytutorial
oc get pods -n mytutorial -o wide
oc get services,deployments,routes,hpa -n mytutorial
oc get imagestreams,buildconfigs -n mytutorial

# ═══════════════════════════════════════════════════
# SECURITY
# ═══════════════════════════════════════════════════
oc describe pod -n mytutorial | grep openshift.io/scc
oc get scc -o name | xargs oc describe | grep -A5 "Users:" | grep mytutorial
oc auth can-i create pods --as system:serviceaccount:mytutorial:mytutorial-sa

# ═══════════════════════════════════════════════════
# APPLICATION LOGS
# ═══════════════════════════════════════════════════
oc logs -n mytutorial -l app=auth-service --tail=50 -f
oc logs deployment/auth-service -n mytutorial --previous

# ═══════════════════════════════════════════════════
# NETWORKING
# ═══════════════════════════════════════════════════
oc get routes -n mytutorial
oc describe route api-gateway -n mytutorial
oc get endpoints -n mytutorial

# ═══════════════════════════════════════════════════
# EVENTS
# ═══════════════════════════════════════════════════
oc get events -n mytutorial --sort-by='.lastTimestamp'
```

---

## Appendix: File Reference

### Directory Structure

```
deploy-openshift/
├── README.md                     ← This guide
├── base/                         ← Standard K8s manifests
│   ├── namespace.yaml
│   ├── configmaps.yaml
│   ├── deployments.yaml          ← Standard K8s Deployments
│   ├── services.yaml
│   ├── hpas.yaml
│   ├── pdbs.yaml
│   ├── network-policies.yaml
│   ├── servicemonitor.yaml       ← Prometheus ServiceMonitor
│   ├── serviceaccount.yaml       ← SCC + service account
│   ├── routes.yaml               ← OpenShift Routes
│   └── kustomization.yaml
├── overlays/
│   ├── dev/                      ← 1 replica, non-TLS routes
│   ├── staging/                  ← 2 replicas, edge TLS
│   ├── prod/                     ← 3 replicas, full TLS + HPA
│   └── openshift/                ← Shared OpenShift patches
│       ├── scc-patches.yaml
│       ├── route-patches.yaml
│       └── kustomization.yaml
├── infrastructure/               ← Same infra as vanilla K8s
│   ├── postgres.yaml
│   ├── redis.yaml
│   ├── kafka.yaml
│   ├── prometheus.yaml
│   ├── grafana.yaml
│   └── elk.yaml
├── templates/                    ← OpenShift Templates
│   ├── mytutorial.yaml           ← Full stack template
│   ├── buildconfigs.yaml         ← S2I/Docker BuildConfigs
│   └── imagestreams.yaml         ← ImageStream definitions
├── pipelines/                    ← OpenShift Pipelines (Tekton)
│   ├── auth-service-pipeline.yaml
│   └── tasks/
│       └── buildah.yaml
└── scripts/
    ├── build-openshift.sh        ← Build & push to internal registry
    ├── deploy-openshift.sh       ← Full deploy with Routes/SCC
    ├── setup-scc.sh              ← Configure SCC permissions
    └── create-projects.sh        ← Create dev/staging/prod projects
```

### Key Differences from `k8s/` (Vanilla K8s)

| Aspect | Vanilla K8s (`k8s/`) | OpenShift (`deploy-openshift/`) |
|--------|---------------------|--------------------------------|
| **CLI** | `kubectl` | `oc` (kubectl also works) |
| **Container registry** | External (ECR/GCR) | OpenShift internal registry |
| **Image pull** | `imagePullSecrets` | `ServiceAccount` with internal registry pull |
| **External traffic** | Ingress (NGINX) | Route (HAProxy) + Ingress |
| **Security** | PodSecurityPolicy | SCC (`anyuid` for JRE) |
| **Deployments** | `Deployment` | `Deployment` or `DeploymentConfig` |
| **Builds** | External CI/CD | Internal BuildConfig (S2I/Docker) |
| **Service Account** | Optional | Required (SCC binding) |
| **Monitoring** | Prometheus Operator | Built-in cluster monitoring |
| **Multi-tenancy** | Namespace | Project (extended namespace) |
| **Templates** | Helm charts | OpenShift Templates + Helm |

### Quick Start

```bash
# 1. Login to OpenShift
oc login https://api.ocp.example.com:6443

# 2. Create project
oc new-project mytutorial

# 3. Apply SCC
oc adm policy add-scc-to-user anyuid -z default -n mytutorial

# 4. Create service account
oc create sa mytutorial-sa -n mytutorial
oc adm policy add-scc-to-user anyuid -z mytutorial-sa -n mytutorial

# 5. Deploy infrastructure
kubectl apply -f infrastructure/ -n mytutorial

# 6. Deploy application
kustomize build overlays/dev | kubectl apply -n mytutorial -f -

# 7. Create routes
oc create route edge api-gateway --service=api-gateway --port=8080 -n mytutorial

# 8. Access
echo "https://$(oc get route api-gateway -n mytutorial --template='{{ .spec.host }}')"
```

---

## References

- [OpenShift Documentation](https://docs.openshift.com/container-platform/latest/)
- [OpenShift CLI Reference (oc)](https://docs.openshift.com/container-platform/latest/cli_reference/openshift_cli/getting-started-cli.html)
- [OpenShift Routes](https://docs.openshift.com/container-platform/latest/networking/routes/route-configuration.html)
- [Security Context Constraints](https://docs.openshift.com/container-platform/latest/authentication/managing-security-context-constraints.html)
- [OpenShift Builds](https://docs.openshift.com/container-platform/latest/builds/understanding-image-builds.html)
- [OpenShift Pipelines (Tekton)](https://docs.openshift.com/pipelines/latest/)
- [OpenShift Service Mesh](https://docs.openshift.com/container-platform/latest/service_mesh/v2x/installing-ossm.html)
- [OpenShift Monitoring](https://docs.openshift.com/container-platform/latest/monitoring/monitoring-overview.html)
- [Red Hat Ecosystem Catalog](https://catalog.redhat.com/)