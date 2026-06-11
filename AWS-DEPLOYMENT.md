# Deploying & Managing Containerized Applications with Kubernetes

This guide covers the full lifecycle of deploying and managing the MyTutorial microservices stack on **Kubernetes** — from cluster setup and manifests to CI/CD, scaling, observability, and day-2 operations. The existing `k8s/` manifests in this repo are designed to work on any conformant Kubernetes cluster (EKS, AKS, GKE, minikube, k3s, etc.).

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites & Tooling](#2-prerequisites--tooling)
3. [Container Images & Registry](#3-container-images--registry)
4. [Kubernetes Manifests Explained](#4-kubernetes-manifests-explained)
5. [Deploying the Application](#5-deploying-the-application)
6. [Exposing Services (Ingress)](#6-exposing-services-ingress)
7. [Configuration & Secrets](#7-configuration--secrets)
8. [CI/CD Pipeline](#8-cicd-pipeline)
9. [Auto-Scaling](#9-auto-scaling)
10. [Observability](#10-observability)
11. [Day-2 Operations](#11-day-2-operations)
12. [Cost & Resource Optimization](#12-cost--resource-optimization)
13. [Troubleshooting](#13-troubleshooting)

---

## 1. Architecture Overview

```
                                    ┌───────────────┐
                                    │   Ingress     │
                                    │  Controller   │
                                    │ (e.g. nginx   │
                                    │  ingress)     │
                                    └───────┬───────┘
                                            │
                                    ┌───────▼───────┐
                                    │   Service     │
                                    │  api-gateway  │
                                    │  Type:ClusterIP│
                                    └───────┬───────┘
                                            │
               ┌────────────────────────────┼────────────────────────────┐
               │                            │                            │
         ┌─────▼──────┐             ┌───────▼───────┐          ┌────────▼────────┐
         │ eureka-    │             │ auth-service   │          │ grades-service  │
         │ server     │             │ Deployment     │          │ Deployment      │
         │ Deployment │             │ 2-10 replicas  │          │ 2-10 replicas   │
         │ 1 replica  │             │ HPA auto-scale │          │ HPA auto-scale  │
         │ Headless    │             │ Liveness check │          │ Liveness check  │
         │ Service    │             │ Readiness check│          │ Readiness check │
         └────────────┘             └───────┬───────┘          └───────┬────────┘
                                            │                          │
                                 ┌──────────▼──────┐          ┌───────▼────────┐
                                 │ notification-svc│          │  Infrastructure│
                                 │ Deployment      │          │  ──────────────│
                                 │ 1-5 replicas    │          │  postgres (SS) │
                                 │ HPA auto-scale   │          │  redis (Deploy)│
                                 └─────────────────┘          │  kafka (SS)    │
                                                               └────────────────┘
```

### What Each Kubernetes Resource Does

| Resource | Purpose | Example |
|----------|---------|---------|
| **Namespace** | Isolates resources within a cluster | `mytutorial` |
| **Deployment** | Declares desired state (image, replicas, probes) | `api-gateway: 2 replicas, port 8080` |
| **Service** | Stable network endpoint to reach pods | `auth-service:8081` via DNS |
| **ConfigMap** | Non-sensitive configuration (env vars) | DB URLs, Kafka brokers, Eureka URL |
| **Secret** | Sensitive data (passwords, tokens) | JWT secret, DB password |
| **HPA** | Auto-scales pods based on CPU/memory | 2-10 replicas, 70% CPU threshold |
| **PDB** | Ensures minimum pods stay up during disruptions | At least 1 pod always running |
| **Ingress** | External HTTP/HTTPS routing to services | `api.mytutorial.io → api-gateway:80` |
| **NetworkPolicy** | Controls pod-to-pod traffic flow | Deny all except intra-namespace |
| **ServiceAccount** | Identity for pods to interact with the API | Used with IRSA on cloud providers |

---

## 2. Prerequisites & Tooling

### Required Tools

```bash
# ── Must have ──
kubectl version --client   # Kubernetes CLI (v1.28+)
docker --version           # Container runtime (v24+)

# ── Strongly recommended ──
kustomize version          # Manifest overlays / env customization
helm version               # Package manager for K8s addons

# ── Nice to have ──
kubectx                    # Quick context switching
kubens                     # Quick namespace switching
stern                      # Multi-pod log tailing
k9s                        # Terminal UI for K8s
kubectl-neat               # Clean up messy YAML output
popeye                     # K8s cluster sanitizer
```

### The `k8s/` Directory Structure

```
k8s/
├── base/                         # Reusable manifests shared everywhere
│   ├── kustomization.yaml        # Composes all base resources
│   ├── namespace.yaml            # Defines "mytutorial" namespace
│   ├── configmaps.yaml           # Env vars for every service
│   ├── deployments.yaml          # Pod specs, containers, probes
│   ├── services.yaml             # Stable network endpoints
│   ├── hpas.yaml                 # Auto-scaling rules
│   ├── pdbs.yaml                 # Disruption budgets
│   └── network-policies.yaml     # Traffic rules
├── overlays/                     # Environment-specific customizations
│   ├── dev/                      # 1 replica, HPA 1-3
│   ├── staging/                  # 2 replicas, medium resources
│   └── prod/                     # 3 replicas, HPA 3-15
├── infrastructure/               # Stateful workloads (dev only)
│   ├── postgres.yaml             # PostgreSQL StatefulSet + PVC
│   ├── redis.yaml                # Redis Deployment
│   └── kafka.yaml                # Zookeeper + Kafka StatefulSets
├── monitoring/                   # Observability stack
│   ├── prometheus.yaml           # Prometheus with pod auto-discovery
│   └── opensearch-stack.yaml     # OpenSearch + Logstash
└── scripts/                      # Helper scripts
    ├── build-and-push.sh/bat
    └── deploy.sh
```

The **Kustomize** layout means a single command deploys to any environment:

```bash
kubectl apply -k k8s/overlays/dev --namespace mytutorial
```

---

## 3. Container Images & Registry

### 3.1 Building Images

Each backend service has a **multi-stage Dockerfile** that builds the JAR inside Maven, then copies it to a minimal JRE runtime:

```dockerfile
# backend/auth-service/Dockerfile
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app
COPY pom.xml ./
COPY eureka-server/pom.xml ./eureka-server/
COPY auth-service/pom.xml ./auth-service/
COPY grades-service/pom.xml ./grades-service/
COPY notification-service/pom.xml ./notification-service/
COPY api-gateway/pom.xml ./api-gateway/
RUN mvn -B dependency:go-offline -q || true
COPY . ./
RUN mvn -B clean package -pl auth-service -am -DskipTests -q

FROM eclipse-temurin:21-jre-alpine
WORKDIR /app
COPY --from=build /app/auth-service/target/*.jar app.jar
EXPOSE 8081
ENTRYPOINT ["java", "-jar", "app.jar"]
```

This pattern is identical across all 5 services — only `-pl` and `EXPOSE` change.

### 3.2 Pushing to a Registry

```bash
# Tag and push to any Docker-compatible registry
REGISTRY=myregistry.io     # Docker Hub, ECR, ACR, GCR, Harbor, etc.
TAG=$(git rev-parse --short HEAD)

for svc in eureka-server auth-service grades-service notification-service api-gateway; do
  docker build \
    -f "backend/$svc/Dockerfile" \
    -t "$REGISTRY/mytutorial/$svc:$TAG" \
    -t "$REGISTRY/mytutorial/$svc:latest" \
    ./backend
  docker push "$REGISTRY/mytutorial/$svc:$TAG"
  docker push "$REGISTRY/mytutorial/$svc:latest"
done
```

### 3.3 Pulling in Kubernetes

Update the image references in `k8s/base/deployments.yaml`:

```yaml
containers:
  - name: auth-service
    image: myregistry.io/mytutorial/auth-service:abc1234   # <-- set your registry
    imagePullPolicy: IfNotPresent
```

Or use Kustomize to set images per overlay:

```yaml
# k8s/overlays/prod/kustomization.yaml
images:
  - name: mytutorial/auth-service
    newName: myregistry.io/mytutorial/auth-service
    newTag: abc1234
```

---

## 4. Kubernetes Manifests Explained

### 4.1 Namespace (`k8s/base/namespace.yaml`)

Isolates all MyTutorial resources from other apps in the cluster:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: mytutorial
```

### 4.2 Deployments (`k8s/base/deployments.yaml`)

Each service is a `Deployment` with:

| Field | Value | Why |
|-------|-------|-----|
| `replicas` | 1-3 (environment-dependent) | Default count |
| `strategy.type` | RollingUpdate | Zero-downtime deploys |
| `rollingUpdate.maxSurge` | 1 | Add 1 pod before removing old |
| `rollingUpdate.maxUnavailable` | 0 | Never have less than desired |
| `livenessProbe` | HTTP GET /actuator/health/liveness | Restart unhealthy pods |
| `readinessProbe` | HTTP GET /actuator/health/readiness | Don't send traffic to unready pods |
| `resources.requests` | CPU + memory minimum | Guaranteed resources for scheduling |
| `resources.limits` | CPU + memory cap | Prevent runaway pods from starving the node |

Full example for auth-service:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: auth-service
  labels:
    app: auth-service
    tier: backend
spec:
  replicas: 2
  selector:
    matchLabels:
      app: auth-service
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: auth-service
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8081"
        prometheus.io/path: "/actuator/prometheus"
    spec:
      containers:
        - name: auth-service
          image: mytutorial/auth-service:latest
          ports:
            - containerPort: 8081
          envFrom:
            - configMapRef: { name: mytutorial-shared }
            - configMapRef: { name: auth-service-config }
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

### 4.3 Services (`k8s/base/services.yaml`)

Services provide stable DNS names for pods (which are ephemeral):

| Service | Type | Cluster DNS | Notes |
|---------|------|-------------|-------|
| `eureka-server` | ClusterIP (None) | `eureka-server:8761` | Headless — for stateful discovery |
| `auth-service` | ClusterIP (None) | `auth-service:8081` | Headless |
| `grades-service` | ClusterIP (None) | `grades-service:8082` | Headless |
| `notification-service` | ClusterIP (None) | `notification-service:8083` | Headless |
| `api-gateway` | ClusterIP | `api-gateway:80` → 8080 | ClusterIP + Ingress for external |

Headless services (`clusterIP: None`) let Eureka discover individual pod IPs directly. The api-gateway uses a regular `ClusterIP` service so the Ingress controller can route traffic to it.

### 4.4 ConfigMaps (`k8s/base/configmaps.yaml`)

ConfigMaps decouple environment-specific configuration from container images:

```yaml
# Shared across all services
apiVersion: v1
kind: ConfigMap
metadata:
  name: mytutorial-shared
data:
  SPRING_PROFILES_ACTIVE: "k8s"
  EUREKA_CLIENT_SERVICEURL_DEFAULTZONE: "http://eureka-server:8761/eureka/"
  LOGGING_LOGSTASH_HOST: "logstash"
  LOGGING_LOGSTASH_PORT: "5000"

# Per-service ConfigMaps override with service-specific values
apiVersion: v1
kind: ConfigMap
metadata:
  name: auth-service-config
data:
  SPRING_APPLICATION_NAME: "auth-service"
  SERVER_PORT: "8081"
  SPRING_DATASOURCE_URL: "jdbc:postgresql://postgres:5432/postgres"
  SPRING_DATASOURCE_USERNAME: "postgres"
  SPRING_DATA_REDIS_HOST: "redis"
  SPRING_KAFKA_BOOTSTRAP_SERVERS: "kafka:9092"
  APP_JWT_SECRET: "dev-only-secret-do-not-use-in-prod"
```

### 4.5 Secrets

For production, use a Secret (or External Secrets Operator → cloud provider Secrets Manager):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: mytutorial-secrets
type: Opaque
data:
  SPRING_DATASOURCE_PASSWORD: bXlwYXNzd29yZA==  # base64 "mypassword"
  APP_JWT_SECRET: M2Y4YTJiMWM5ZDRlNWY2YTdiOGM5ZDBlMWYyYTNiNGM1ZDZlN2Y4YTliMGMxZDJlM2Y0YTViNmM3ZDhlOWYwYQ==
```

And mount it in deployments:

```yaml
envFrom:
  - configMapRef: { name: mytutorial-shared }
  - configMapRef: { name: auth-service-config }
  - secretRef: { name: mytutorial-secrets }    # <-- add this
```

### 4.6 Spring Profile: `application-k8s.yml`

Each service has a `application-k8s.yml` that activates when `SPRING_PROFILES_ACTIVE=k8s`:

```yaml
# backend/auth-service/src/main/resources/application-k8s.yml
spring:
  data:
    redis:
      host: redis
  kafka:
    bootstrap-servers: kafka:9092
  datasource:
    url: jdbc:postgresql://postgres:5432/postgres
eureka:
  client:
    service-url:
      defaultZone: http://eureka-server:8761/eureka/
management:
  endpoint:
    health:
      probes:
        enabled: true
```

This means all K8s-specific networking (service DNS names) is handled at the Spring level — no hardcoded IPs or hostnames in the Docker image.

### 4.7 Kustomize Overlays

| Overlay | Replicas | HPA | Resources | Use Case |
|---------|----------|-----|-----------|----------|
| **dev** | 1 | 1→3 | Base | Local dev, minikube, CI test |
| **staging** | 2 | 2→10 | Medium requests | QA, pre-prod validation |
| **prod** | 3 | 3→15 | Standard limits | Production traffic |

An overlay patches only what differs from base:

```yaml
# k8s/overlays/dev/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../base

namePrefix: dev-

commonLabels:
  environment: dev

patches:
  - patch: |-
      - op: replace
        path: /spec/replicas
        value: 1
    target:
      kind: Deployment
      name: auth-service|grades-service|api-gateway
  - patch: |-
      - op: replace
        path: /spec/minReplicas
        value: 1
      - op: replace
        path: /spec/maxReplicas
        value: 3
    target:
      kind: HorizontalPodAutoscaler
```

---

## 5. Deploying the Application

### 5.1 Local Development (minikube / kind / k3s)

```bash
# Start a local cluster
minikube start --cpus 4 --memory 8192
# or: kind create cluster --name mytutorial
# or: k3d cluster create mytutorial

# Build images into the local cluster
eval $(minikube docker-env)
for svc in eureka-server auth-service grades-service notification-service api-gateway; do
  docker build -f "backend/$svc/Dockerfile" -t "mytutorial/$svc:latest" ./backend
done

# Deploy everything (app + infrastructure + monitoring)
kustomize build k8s/overlays/dev | kubectl apply -f -

# Wait for pods
kubectl get pods -n mytutorial -w

# Access the gateway
kubectl port-forward -n mytutorial service/api-gateway 8080:80

# Test
curl http://localhost:8080/actuator/health
```

### 5.2 Production Cluster (Any Provider)

```bash
# 1. Point your kubectl at the cluster
kubectl config use-context my-cluster-context

# 2. Create namespace
kubectl apply -f k8s/base/namespace.yaml

# 3. Deploy infrastructure (if not using managed services like RDS/ElastiCache)
kubectl apply -f k8s/infrastructure/

# 4. Set correct image registry in the overlay
# Edit k8s/overlays/prod/kustomization.yaml to set your registry URL

# 5. Deploy application
kustomize build k8s/overlays/prod | kubectl apply -n mytutorial -f -

# 6. Deploy monitoring
kubectl apply -n mytutorial -f k8s/monitoring/

# 7. Verify
kubectl rollout status deployment/api-gateway -n mytutorial
kubectl get pods,services,hpa -n mytutorial
```

### 5.3 Deploy Script

```bash
#!/bin/bash
# k8s/scripts/deploy.sh
set -euo pipefail

ENV=${1:-dev}
NAMESPACE=${NAMESPACE:-mytutorial}

echo "=== Deploying MyTutorial (${ENV}) ==="

# Create namespace if not exists
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# Deploy infrastructure
kubectl apply -f k8s/infrastructure/ -n "${NAMESPACE}"

# Deploy monitoring
kubectl apply -f k8s/monitoring/ -n "${NAMESPACE}"

# Deploy application via Kustomize
kustomize build "k8s/overlays/${ENV}" | kubectl apply -n "${NAMESPACE}" -f -

# Wait for rollouts
for svc in eureka-server auth-service grades-service notification-service api-gateway; do
  kubectl rollout status "deployment/$svc" -n "${NAMESPACE}" --timeout=180s || true
done

echo "=== Deploy complete ==="
```

### 5.4 Deployment Order Matters

Because services depend on each other (via Eureka), deploy in this order:

1. **Infrastructure** — postgres, redis, kafka, zookeeper
2. **eureka-server** — must be up so other services can register
3. **auth-service, grades-service, notification-service** — register with Eureka
4. **api-gateway** — last, once routes are resolvable

The `deployments.yaml` doesn't enforce this via `initContainers` — it relies on Eureka's retry logic. Spring Boot services will retry registration if Eureka isn't available yet.

---

## 6. Exposing Services (Ingress)

### 6.1 Install an Ingress Controller

Choose one (not both):

```bash
# Option A: NGINX Ingress (works everywhere — minikube, cloud, bare-metal)
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.0/deploy/static/provider/cloud/deploy.yaml

# Option B: AWS Load Balancer Controller (EKS only — provisions ALB)
# See AWS-DEPLOYMENT.md for EKS-specific setup
```

### 6.2 Create an Ingress Resource

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: api-gateway
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /$2
spec:
  ingressClassName: nginx
  rules:
    - host: api.mytutorial.io
      http:
        paths:
          - path: /api(/|$)(.*)
            pathType: ImplementationSpecific
            backend:
              service:
                name: api-gateway
                port:
                  number: 80
    - host: app.mytutorial.io
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: frontend
                port:
                  number: 80
```

### 6.3 TLS with cert-manager

```bash
# Install cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.15.0/cert-manager.yaml

# Create a ClusterIssuer for Let's Encrypt
kubectl apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@mytutorial.io
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - http01:
          ingress:
            class: nginx
EOF

# Annotate the Ingress to request a certificate
kubectl annotate ingress api-gateway \
  cert-manager.io/cluster-issuer=letsencrypt-prod
```

### 6.4 Alternatives for Exposing Services

| Method | Best For | How |
|--------|----------|-----|
| **Ingress + NGINX** | Most clusters | Ingress resource → NGINX → Service → Pods |
| **Ingress + cloud LB** | EKS/AKS/GKE | Provisions a cloud load balancer automatically |
| **kubectl port-forward** | Local dev/debug | `kubectl port-forward svc/api-gateway 8080:80` |
| **NodePort service** | Bare-metal without LB | `service.spec.type: NodePort` → node_ip:high_port |
| **LoadBalancer service** | Cloud clusters that support it | `service.spec.type: LoadBalancer` → provisions a cloud LB |

---

## 7. Configuration & Secrets

### 7.1 Environment Variables (ConfigMap)

ConfigMaps feed environment variables into containers. The existing `configmaps.yaml` uses a **shared ConfigMap** (common across services) plus **per-service ConfigMaps**:

```
Pod
├── ConfigMap mytutorial-shared
│   ├── EUREKA_CLIENT_SERVICEURL_DEFAULTZONE
│   ├── SPRING_PROFILES_ACTIVE
│   └── LOGGING_LOGSTASH_HOST
├── ConfigMap auth-service-config
│   ├── SPRING_DATASOURCE_URL
│   ├── SPRING_DATA_REDIS_HOST
│   └── APP_JWT_SECRET          ← actually should be in Secret
└── Secret mytutorial-secrets
    ├── SPRING_DATASOURCE_PASSWORD
    └── APP_JWT_SECRET           ← override from Secret
```

To update a ConfigMap:

```bash
# Edit the ConfigMap
kubectl edit configmap auth-service-config -n mytutorial

# Or apply a new version
kubectl apply -f k8s/base/configmaps.yaml

# Restart deployments to pick up changes
kubectl rollout restart deployment/auth-service -n mytutorial
```

### 7.2 Secrets

Never put passwords or tokens in ConfigMaps. Use Secrets for sensitive data:

```bash
# Create a Secret from literal values
kubectl create secret generic mytutorial-secrets \
  --from-literal=SPRING_DATASOURCE_PASSWORD=mypassword \
  --from-literal=APP_JWT_SECRET=3f8a2b1c9d4e5f6a7b8c9d... \
  -n mytutorial

# Or from a file
kubectl create secret generic mytutorial-secrets \
  --from-file=./secrets.properties \
  -n mytutorial
```

### 7.3 External Secrets Operator (Production)

For production, don't store secrets in Git at all. Use **External Secrets Operator** to sync from a secrets store:

```bash
# Install the operator
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace
```

```yaml
# SecretStore: tells ESO where secrets live
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: aws-secretstore          # or gcp-secretstore, azure-keyvault
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-1
      auth:
        jwt:
          serviceAccountRef:
            name: mytutorial-sa

---
# ExternalSecret: defines what to fetch
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: mytutorial-secrets
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secretstore
    kind: SecretStore
  target:
    name: mytutorial-secrets
  data:
    - secretKey: SPRING_DATASOURCE_PASSWORD
      remoteRef:
        key: /mytutorial/db-password
    - secretKey: APP_JWT_SECRET
      remoteRef:
        key: /mytutorial/jwt-secret
        property: key
```

### 7.4 Using Spring Profiles Across Environments

| Profile | When Active | Used For |
|---------|-------------|----------|
| `k8s` | K8s deployment (`SPRING_PROFILES_ACTIVE=k8s`) | K8s service DNS hostnames |
| `docker` | Docker Compose | Docker service names |
| `default` | Local dev | Localhost + fixed IPs |

The profile activates via `env` in the Deployment:

```yaml
env:
  - name: SPRING_PROFILES_ACTIVE
    value: "k8s"
```

---

## 8. CI/CD Pipeline

### 8.1 Generic GitHub Actions Pipeline

This pipeline works with **any** Kubernetes cluster — just set the right kubeconfig secret:

```yaml
# .github/workflows/deploy-k8s.yml
name: Deploy to Kubernetes

on:
  push:
    branches: [main]
    paths:
      - 'backend/**'

env:
  REGISTRY: myregistry.io          # Your container registry
  K8S_NAMESPACE: mytutorial

jobs:
  test:
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

  build-and-push:
    needs: test
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Login to container registry
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ secrets.REGISTRY_USER }}
          password: ${{ secrets.REGISTRY_PASSWORD }}

      - name: Build and push images
        env:
          TAG: ${{ github.sha }}
        run: |
          for svc in eureka-server auth-service grades-service notification-service api-gateway; do
            docker build -f "backend/$svc/Dockerfile" \
              -t "$REGISTRY/mytutorial/$svc:$TAG" \
              -t "$REGISTRY/mytutorial/$svc:latest" \
              ./backend
            docker push "$REGISTRY/mytutorial/$svc:$TAG"
            docker push "$REGISTRY/mytutorial/$svc:latest"
          done

  deploy:
    needs: build-and-push
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Set up kubectl
        uses: azure/setup-kubectl@v4
        with:
          version: 'latest'

      - name: Set kubeconfig
        run: |
          mkdir -p $HOME/.kube
          echo "${{ secrets.KUBECONFIG }}" | base64 -d > $HOME/.kube/config

      - name: Deploy with Kustomize
        run: |
          # Update image tags in the overlay
          cd k8s
          for svc in eureka-server auth-service grades-service notification-service api-gateway; do
            kustomize edit set image "mytutorial/$svc=$REGISTRY/mytutorial/$svc:${{ github.sha }}"
          done

          kustomize build overlays/prod | \
            kubectl apply -n $K8S_NAMESPACE -f -

      - name: Verify rollout
        run: |
          for svc in eureka-server auth-service grades-service notification-service api-gateway; do
            kubectl rollout status deployment/$svc -n $K8S_NAMESPACE --timeout=300s
          done

      - name: Health check
        run: |
          kubectl run health-check --image=curlimages/curl --restart=Never -- \
            curl -sf http://api-gateway:80/actuator/health
          kubectl delete pod health-check --ignore-not-found
```

### 8.2 GitOps with ArgoCD

For production teams, use **GitOps** — the Git repo is the source of truth:

```bash
# Install ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Create an Application that syncs from Git
kubectl apply -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: mytutorial
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/mytutorial.git
    targetBranch: main
    path: k8s/overlays/prod
  destination:
    server: https://kubernetes.default.svc
    namespace: mytutorial
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF
```

ArgoCD will:
1. Watch Git for changes to `k8s/overlays/prod/`
2. On every push, apply the new manifests
3. Automatically revert (self-heal) if someone manually edits cluster state
4. Show the sync status and diff in the ArgoCD UI

---

## 9. Auto-Scaling

### 9.1 Horizontal Pod Autoscaler (HPA)

The existing `hpas.yaml` scales pods based on resource metrics:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: auth-service-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: auth-service
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 80
```

How it works:

```
HPA Controller
     │
     ├── Reads metrics from Metrics Server (CPU/memory per pod)
     │
     ├── Calculates desired replicas:
     │     desired = ceil(current_replicas × current_metric / target_metric)
     │     Example: 2 pods at 85% CPU → ceil(2 × 85/70) = 3 pods
     │
     └── Updates Deployment replicas
```

Commands:

```bash
# Watch HPA status
kubectl get hpa -n mytutorial -w
kubectl describe hpa auth-service-hpa -n mytutorial

# Manual scale test
kubectl run load-test --image=alpine --rm -it --restart=Never -- \
  sh -c "apk add curl; while true; do curl -s http://auth-service:8081/actuator/health; done"
```

### 9.2 Vertical Pod Autoscaler (VPA)

VPA right-sizes CPU/memory requests by analyzing actual usage:

```bash
# Install VPA
kubectl apply -f https://raw.githubusercontent.com/kubernetes/autoscaler/master/vertical-pod-autoscaler/deploy/recommender.yaml

# Create VPA for auth-service (recommendation mode only)
kubectl apply -f - <<'EOF'
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: auth-service-vpa
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: auth-service
  updatePolicy:
    updateMode: "Off"           # Only recommend, don't auto-update
  resourcePolicy:
    containerPolicies:
      - containerName: '*'
        minAllowed:
          cpu: 200m
          memory: 256Mi
        maxAllowed:
          cpu: 2
          memory: 2Gi
EOF

# View recommendations
kubectl describe vpa auth-service-vpa -n mytutorial
# Output:
#   Container Recommendations:
#     Target:
#       cpu: 350m
#       memory: 768Mi
#     Lower Bound:
#       cpu: 250m
#       memory: 512Mi
#     Upper Bound:
#       cpu: 800m
#       memory: 1Gi
```

### 9.3 Scaling Summary

| Layer | Controller | What It Does | Response Time |
|-------|-----------|-------------|---------------|
| **Pod** | HPA | Adds/removes replicas based on CPU/memory | ~30 seconds |
| **Pod** | VPA | Recommends CPU/memory request sizes | Hours (needs historical data) |
| **Node** | Cluster Autoscaler | Adds/removes nodes when pods are Pending | ~2-5 minutes |
| **Node** | Karpenter | Provisions optimal nodes instantly | ~30-60 seconds |

### 9.4 Pod Disruption Budgets

PDBs ensure high availability during voluntary disruptions (node drains, rolling updates):

```yaml
# Already applied via k8s/base/pdbs.yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: api-gateway-pdb
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: api-gateway
```

This guarantees at least 1 pod of `api-gateway` stays up when the cluster drains nodes.

---

## 10. Observability

### 10.1 Logging

**The ELK Stack** runs in-cluster via `k8s/monitoring/opensearch-stack.yaml`:

```
Spring Boot (JSON logs) → LogstashTCPAppender → Logstash → OpenSearch → OpenSearch Dashboards
                                   :5000                  :9200              :5601
```

Each service's `logback-spring.xml` sends structured JSON to Logstash via TCP:

```xml
<appender name="LOGSTASH" class="net.logstash.logback.appender.LogstashTcpSocketAppender">
    <destination>logstash:5000</destination>
    <encoder class="net.logstash.logback.encoder.LogstashEncoder">
        <includeMdc>true</includeMdc>
        <customFields>{"app_name":"${APP_NAME}"}</customFields>
    </encoder>
</appender>
```

**Quick log access:**

```bash
# Tail logs from all auth-service pods
kubectl logs -n mytutorial -l app=auth-service --tail=50 -f

# Using stern (better for multi-pod scenarios)
stern auth-service -n mytutorial

# From a specific pod
kubectl logs -n mytutorial auth-service-6f7d8c9d5-abc12 --previous
```

### 10.2 Metrics (Prometheus)

Prometheus auto-discovers pods via annotations:

```yaml
# Added to every Deployment's pod template
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "8081"
  prometheus.io/path: "/actuator/prometheus"
```

Spring Boot exposes metrics at `/actuator/prometheus` via:

```xml
<!-- backend/pom.xml -->
<dependency>
    <groupId>io.micrometer</groupId>
    <artifactId>micrometer-registry-prometheus</artifactId>
</dependency>
```

Deploy Prometheus:

```bash
kubectl apply -f k8s/monitoring/prometheus.yaml
kubectl port-forward -n mytutorial service/prometheus 9090:9090
# Open http://localhost:9090 → Query: jvm_memory_used_bytes
```

Or use the Prometheus Operator (production):

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  -n prometheus --create-namespace
```

### 10.3 Metrics Available

Each service exposes hundreds of metrics. Key ones to watch:

| Metric | Type | What It Tells You |
|--------|------|-------------------|
| `jvm_memory_used_bytes` | Gauge | Heap/non-heap usage |
| `jvm_gc_pause_seconds` | Summary | GC pause time |
| `http_server_requests_seconds` | Histogram | Request latency (p50, p95, p99) |
| `jvm_threads_live_threads` | Gauge | Active threads |
| `logback_events_total` | Counter | Log rate (by level) |
| `hikaricp_connections_active` | Gauge | Active DB connections |
| `process_cpu_usage` | Gauge | CPU utilization |
| `kafka_consumer_*` | Gauge | Consumer lag |

### 10.4 Dashboards

The included **JVM (Micrometer)** dashboard (`docker/monitoring/grafana/provisioning/dashboards/jvm-micrometer.json`) works out of the box with Prometheus. To import:

**Via Grafana UI:**
1. Deploy Grafana: `helm install grafana grafana/grafana -n grafana --create-namespace`
2. Add Prometheus datasource → URL: `http://prometheus:9090`
3. Import dashboard → Upload `jvm-micrometer.json`

### 10.5 Health Probes

Every service has two probes:

| Probe | Path | Delay | Period | What Happens on Failure |
|-------|------|-------|--------|------------------------|
| **Liveness** | `/actuator/health/liveness` | 40-60s | 15s | Kubelet restarts the container |
| **Readiness** | `/actuator/health/readiness` | 20-30s | 10s | Service stops routing traffic to the pod |

Enabled via Spring Boot Actuator:

```yaml
# application-k8s.yml
management:
  endpoint:
    health:
      probes:
        enabled: true
  health:
    readinessstate:
      enabled: true
    livenessstate:
      enabled: true
```

---

## 11. Day-2 Operations

### 11.1 Rolling Updates

With `maxSurge: 1` and `maxUnavailable: 0`, updates happen without downtime:

```bash
# Trigger a rolling restart (e.g., after ConfigMap change)
kubectl rollout restart deployment/auth-service -n mytutorial

# Watch the rollout
kubectl rollout status deployment/auth-service -n mytutorial

# Rollback to a previous revision
kubectl rollout undo deployment/auth-service -n mytutorial
kubectl rollout undo deployment/auth-service -n mytutorial --to-revision=2

# View revision history
kubectl rollout history deployment/auth-service -n mytutorial
```

### 11.2 Updating Images

```bash
# Update the image and trigger a rollout
kubectl set image deployment/auth-service \
  auth-service=myregistry.io/mytutorial/auth-service:v2.1.0 \
  -n mytutorial

# Or edit the deployment directly
kubectl edit deployment auth-service -n mytutorial
```

### 11.3 Canary Deployments

Use **Argo Rollouts** for advanced traffic-splitting:

```bash
# Install
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
```

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: auth-service
spec:
  replicas: 4
  strategy:
    canary:
      steps:
        - setWeight: 10
        - pause: { duration: 2m }
        - setWeight: 50
        - pause: { duration: 2m }
        - setWeight: 100
  selector:
    matchLabels:
      app: auth-service
  template:
    metadata:
      labels:
        app: auth-service
    spec:
      containers:
        - name: auth-service
          image: mytutorial/auth-service:new-version
```

### 11.4 Backup and Restore

```bash
# Backup Kubernetes resources
kubectl get all -n mytutorial -o yaml > mytutorial-backup.yaml

# Backup etcd (with Velero)
velero install --provider aws --bucket mytutorial-backups \
  --backup-location-config region=us-east-1 \
  --plugins velero/velero-plugin-for-aws:v1.0.0

# Schedule nightly backup
velero schedule create daily-backup \
  --schedule "0 3 * * *" \
  --include-namespaces mytutorial
```

### 11.5 Resource Quotas & Limits

```bash
# Limit total resources in the namespace
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ResourceQuota
metadata:
  name: mytutorial-quota
spec:
  hard:
    requests.cpu: "4"
    requests.memory: "8Gi"
    limits.cpu: "8"
    limits.memory: "16Gi"
    persistentvolumeclaims: "5"
    pods: "30"
EOF
```

### 11.6 Upgrading the Cluster

```bash
# Check current version
kubectl version

# Drain and upgrade nodes (cloud-specific)
# EKS: eksctl upgrade nodegroup
# AKS: az aks upgrade
# GKE: gcloud container clusters upgrade

# After upgrade, restart apps
kubectl rollout restart deployment -n mytutorial
```

---

## 12. Cost & Resource Optimization

### 12.1 Right-Sizing with VPA

Use VPA recommendations to set accurate `resources.requests` in your manifests:

```bash
kubectl describe vpa auth-service-vpa -n mytutorial | grep -A6 "Container Recommendations"
```

Then update the base Deployment with the recommended values.

### 12.2 Spot Instances (Cloud Clusters)

For stateless services (auth, grades, gateway), use spot/preemptible instances:

```yaml
# NodeSelector or NodeAffinity to prefer spot nodes
affinity:
  nodeAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        preference:
          matchExpressions:
            - key: karpenter.sh/capacity-type
              operator: In
              values:
                - spot
```

### 12.3 Limit Monitoring Costs

```bash
# Set Prometheus retention to 24h (enough for HPA data)
# Set CloudWatch / Loki log retention to 7 days for dev
```

### 12.4 Avoid Over-Provisioning

| Service | Initial Request | After VPA Tuning | Savings |
|---------|----------------|-----------------|---------|
| auth-service | 300m CPU / 512Mi | 250m CPU / 400Mi | ~20% |
| api-gateway | 300m CPU / 512Mi | 200m CPU / 350Mi | ~30% |
| notification-service | 200m CPU / 384Mi | 150m CPU / 300Mi | ~25% |

### 12.5 Resource Quotas

Prevent a single team/service from consuming all cluster resources:

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ResourceQuota
metadata:
  name: mytutorial-quota
spec:
  hard:
    requests.cpu: "4"
    requests.memory: "8Gi"
    limits.cpu: "8"
    limits.memory: "16Gi"
    persistentvolumeclaims: "5"
    pods: "30"
EOF
```

---

## 13. Troubleshooting

### 13.1 Pod Stuck in Pending

```bash
kubectl describe pod auth-service-xxxxx -n mytutorial

# Common causes:
# ── "0/3 nodes are available: 3 Insufficient cpu"
#    → Not enough cluster capacity. Add nodes or reduce requests.
# ── "0/3 nodes are available: 3 node(s) didn't match pod affinity/anti-affinity"
#    → Check nodeSelector / affinity rules.
# ── "0/3 nodes are available: 3 node(s) had untolerated taint"
#    → Pod needs tolerations for node taints.
```

### 13.2 Pod in CrashLoopBackOff

```bash
# Check why it's crashing
kubectl logs auth-service-xxxxx -n mytutorial --previous
kubectl describe pod auth-service-xxxxx -n mytutorial | grep -A10 "State:"

# Common causes:
# ── OOMKilled → Out of memory. Increase memory limits.
# ── Error: failed to start container → Check env vars and config.
# ── Failed to bind to port → Port already in use. Check PORT env.
```

### 13.3 ImagePullBackOff

```bash
kubectl describe pod auth-service-xxxxx -n mytutorial | grep Image

# Check:
# ── Image name is correct
# ── Image exists in the registry
# ── Pod has pull credentials (imagePullSecrets)
# ── Registry is reachable from the cluster

# Create pull secret if needed:
kubectl create secret docker-registry regcred \
  --docker-server=myregistry.io \
  --docker-username=user \
  --docker-password=pass \
  -n mytutorial

# Add to deployment:
# spec.template.spec.imagePullSecrets:
#   - name: regcred
```

### 13.4 Service Not Reachable

```bash
# Test DNS resolution
kubectl run dnstest --image=alpine --rm -it -n mytutorial -- \
  nslookup auth-service

# Test endpoint connectivity
kubectl run curltest --image=curlimages/curl --rm -it -n mytutorial -- \
  curl -sv http://auth-service:8081/actuator/health

# Check endpoints
kubectl get endpoints auth-service -n mytutorial

# Check service ports match pod containerPort
kubectl get service auth-service -n mytutorial -o yaml | grep -A5 ports
kubectl get pod -l app=auth-service -n mytutorial -o yaml | grep containerPort
```

### 13.5 HPA Not Scaling

```bash
# Check metrics server
kubectl top pods -n mytutorial

# Check HPA status
kubectl describe hpa auth-service-hpa -n mytutorial
# Look for:
#   Conditions:
#     AbleToScale:   True
#     ScalingActive: True
#     ScalingLimited: False
#   Metrics:
#     cpu: 45% (below 70% target)

# If no metrics: Metrics Server not installed
kubectl get pods -n kube-system | grep metrics-server

# If metrics show 0%: pods missing resource.requests
kubectl get pod auth-service-xxxxx -n mytutorial -o yaml | grep resources -A5
```

### 13.6 Ingress Not Working

```bash
# Check ingress controller logs
kubectl logs -n ingress-nginx deployment/ingress-nginx-controller

# Verify ingress resource
kubectl describe ingress api-gateway -n mytutorial

# Check endpoints are healthy
kubectl get endpoints api-gateway -n mytutorial

# Test via port-forward first (bypasses ingress)
kubectl port-forward svc/api-gateway 8080:80 -n mytutorial
```

### 13.7 Common Commands Reference

```bash
# ── Pod management ──
kubectl get pods -n mytutorial -o wide
kubectl logs -n mytutorial -l app=auth-service --tail=50 -f
kubectl exec -it -n mytutorial deployment/auth-service -- /bin/sh
kubectl top pods -n mytutorial

# ── Debugging ──
kubectl describe node <node-name>
kubectl get events -n mytutorial --sort-by='.lastTimestamp'

# ── Scaling ──
kubectl get hpa -n mytutorial
kubectl scale deployment/auth-service --replicas=5 -n mytutorial

# ── Rollouts ──
kubectl rollout status deployment/auth-service -n mytutorial
kubectl rollout undo deployment/auth-service -n mytutorial

# ── Configuration ──
kubectl get configmaps -n mytutorial
kubectl get secrets -n mytutorial
kubectl describe configmap auth-service-config -n mytutorial

# ── Networking ──
kubectl get services -n mytutorial
kubectl get endpoints -n mytutorial
kubectl get ingress -n mytutorial

# ── Cluster health ──
kubectl cluster-info
kubectl get nodes -o wide
kubectl get componentstatuses
```

---

## Appendix: Mapping Docker Compose → Kubernetes

| Docker Compose | Kubernetes Equivalent | Notes |
|---------------|----------------------|-------|
| `service.ports` | `Service.ports` + `Deployment.containerPort` | Stable DNS endpoint |
| `service.environment` | `ConfigMap` + `Secret` + `envFrom` | Decouple config from images |
| `service.volumes` | `PersistentVolumeClaim` + `volumeMounts` | For stateful data |
| `service.depends_on` | `initContainers` or startup retry logic | K8s doesn't have depends_on |
| `service.healthcheck` | `livenessProbe` + `readinessProbe` | Health-aware traffic routing |
| `service.deploy.replicas` | `Deployment.replicas` | Desired pod count |
| `docker network` | `Namespace` + `NetworkPolicy` | Network isolation |
| `docker-compose up -d` | `kubectl apply -f manifest.yaml` | Declarative apply |
| `docker-compose logs -f` | `stern service-name -n mytutorial` | Multi-pod log streaming |
| `docker-compose scale svc=5` | `kubectl scale deployment/svc --replicas=5` | Manual scaling |
| `docker build .` | Docker build + push to registry | Images must be in a registry |

---

## References

- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [Kustomize Documentation](https://kubectl.docs.kubernetes.io/guides/)
- [Spring Boot on Kubernetes](https://spring.io/guides/gs/spring-boot-kubernetes/)
- [Prometheus Operator](https://prometheus-operator.dev/)
- [External Secrets Operator](https://external-secrets.io/)
- [ArgoCD - GitOps for Kubernetes](https://argo-cd.readthedocs.io/)
- [Argo Rollouts - Progressive Delivery](https://argoproj.github.io/rollouts/)
- [cert-manager - TLS Certificates](https://cert-manager.io/)
- [Velero - Backup & Restore](https://velero.io/)
- [K9s - Terminal UI](https://k9scli.io/)