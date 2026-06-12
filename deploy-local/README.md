# Deploying & Managing Containerized Applications Locally with Minikube

This is a self-contained deployment package for running the MyTutorial microservices stack on **local/on-premises infrastructure using Minikube**. Everything you need is in this folder — no external dependencies on cloud services, no container registry required.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites & Installation](#2-prerequisites--installation)
3. [Quick Start](#3-quick-start)
4. [Building Images into Minikube](#4-building-images-into-minikube)
5. [Deploying the Stack](#5-deploying-the-stack)
6. [Accessing Services](#6-accessing-services)
7. [Environment Overlays](#7-environment-overlays)
8. [Monitoring & Observability](#8-monitoring--observability)
9. [Managing the Cluster](#9-managing-the-cluster)
10. [Persistence & Storage](#10-persistence--storage)
11. [CI/CD for Local Deployments](#11-cicd-for-local-deployments)
12. [Troubleshooting](#12-troubleshooting)

---

## 1. Architecture Overview

This package deploys the full MyTutorial stack on a **single-node Minikube VM** running on your local machine or on-premises server:

```
                          ┌──────────────────┐
                          │   Minikube VM    │
                          │  (Docker Driver  │
                          │   or bare-metal) │
                          └────────┬─────────┘
                                   │
                    ┌──────────────┼──────────────┐
                    │              │              │
              ┌─────▼──────┐ ┌────▼──────┐ ┌─────▼──────┐
              │ Ingress    │ │ api-      │ │ auth-      │
              │ NGINX      │ │ gateway   │ │ service    │
              │ :80/443    │ │ :8080     │ │ :8081      │
              │ (addon)    │ │ 1-3 pods  │ │ 1-3 pods   │
              └────────────┘ └─────┬──────┘ └──────┬─────┘
                                   │                │
                             ┌─────▼──────┐  ┌──────▼─────┐
                             │ eureka-    │  │ grades-    │
                             │ server     │  │ service    │
                             │ :8761      │  │ :8082      │
                             │ 1 pod      │  │ 1-3 pods   │
                             └────────────┘  └──────┬─────┘
                                                     │
                                              ┌──────▼─────┐
                                              │ notifica-  │
                                              │ tion-svc   │
                                              │ :8083      │
                                              │ 1-2 pods   │
                                              └────────────┘
                                   │
                    ┌──────────────┼──────────────┐
                    │              │              │
              ┌─────▼──────┐ ┌────▼──────┐ ┌─────▼──────┐
              │ PostgreSQL │ │ Redis     │ │ Kafka      │
              │ Port:5432  │ │ Port:6379 │ │ Port:9092  │
              │ StatefulSet│ │ Deployment│ │ StatefulSet│
              │ PVC:5Gi    │ │           │ │ PVC:5Gi    │
              └────────────┘ └───────────┘ └────────────┘
```

### Key Differences from Cloud Deployments

| Feature | Cloud (EKS/GKE/AKS) | Local (Minikube) |
|---------|---------------------|-------------------|
| **Registry** | ECR, Artifact Registry, ACR | Minikube's internal Docker daemon |
| **Load balancer** | Cloud LB (ALB, HTTP LB) | `minikube tunnel` or `kubectl port-forward` |
| **Storage** | EBS, Persistent Disk, Azure Disk | Minikube `standard` StorageClass (hostPath) |
| **DNS** | Route 53, Cloud DNS, Azure DNS | Local `/etc/hosts` or `minikube ip` |
| **SSL** | ACM, Google-managed certs | Self-signed or mkcert |
| **Nodes** | 3-100+ | 1 (single-node cluster) |
| **Cost** | Pay-per-use | Free (local resources only) |
| **Images** | Push to remote registry | Build directly into Minikube |

---

## 2. Prerequisites & Installation

### System Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| **CPU** | 4 cores | 8 cores |
| **Memory** | 8 GB | 16 GB |
| **Disk** | 20 GB free | 50 GB free (SSD) |
| **OS** | Linux, macOS, Windows | Linux (Ubuntu 22.04+) |

### Install Minikube

```bash
# ── Linux ──
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube

# ── macOS ──
brew install minikube

# ── Windows ──
choco install minikube
# Or download from: https://minikube.sigs.k8s.io/docs/start/
```

### Install Other Dependencies

```bash
# ── kubectl ──
# Linux:
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install kubectl /usr/local/bin/kubectl

# macOS: brew install kubectl
# Windows: choco install kubernetes-cli

# ── kustomize ──
curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
sudo mv kustomize /usr/local/bin/

# ── Docker ──
# Linux: sudo apt install docker.io
# macOS: brew install docker
# Windows: choco install docker-desktop

# ── helm (optional, for addons) ──
# Linux/macOS: brew install helm
# Windows: choco install kubernetes-helm
```

### Verify Installation

```bash
minikube version
kubectl version --client
docker --version
```

---

## 3. Quick Start

```bash
# 1. Start Minikube with sufficient resources
minikube start --cpus 4 --memory 8192 --disk-size 20g

# 2. Enable required addons
minikube addons enable ingress
minikube addons enable metrics-server
minikube addons enable dashboard

# 3. Build all images into Minikube
./scripts/build-all.sh

# 4. Deploy everything
./scripts/deploy-local.sh dev

# 5. Wait for pods
kubectl get pods -n mytutorial -w

# 6. Access the application
kubectl port-forward -n mytutorial service/api-gateway 8080:80

# 7. Test
curl http://localhost:8080/actuator/health

# 8. Open Minikube Dashboard
minikube dashboard
```

---

## 4. Building Images into Minikube

### 4.1 Point Docker to Minikube's Daemon

The key difference from cloud deployments: instead of pushing to a remote registry, you build directly into Minikube's Docker daemon:

```bash
# Point your shell to minikube's Docker daemon
eval $(minikube docker-env)

# Verify — this should show minikube's Docker, not your host Docker
docker info | grep "Server Version"
```

### 4.2 Build All Services

```bash
# With minikube docker-env active, build all images:
eval $(minikube docker-env)

cd ../../backend

for svc in eureka-server auth-service grades-service notification-service api-gateway; do
  echo "Building $svc..."
  docker build \
    -f "$svc/Dockerfile" \
    -t "mytutorial/$svc:latest" \
    .
done

cd ../"deploy-local"
```

### 4.3 Build Script

```bash
#!/bin/bash
# scripts/build-all.sh
set -euo pipefail

echo "=== Building all MyTutorial images into Minikube ==="

# Ensure we're pointing at minikube's Docker
eval $(minikube docker-env)

# Build infra images (only if you want custom infra)
# docker pull postgres:16-alpine  # already available

# Build backend services
cd ../../backend
for svc in eureka-server auth-service grades-service notification-service api-gateway; do
  echo "--- Building $svc ---"
  docker build \
    -f "$svc/Dockerfile" \
    -t "mytutorial/$svc:latest" \
    .
done
cd ../"deploy-local"

# List images inside minikube
echo ""
echo "=== Images in Minikube ==="
docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}" | grep mytutorial

echo ""
echo "=== Build complete ==="
```

### 4.4 Rebuild a Single Service

```bash
eval $(minikube docker-env)
cd ../../backend
docker build -f auth-service/Dockerfile -t mytutorial/auth-service:latest .
cd ../"deploy=local"
kubectl rollout restart deployment/auth-service -n mytutorial
```

### 4.5 Why No Registry?

Minikube runs its own Docker daemon inside the VM. When you run `eval $(minikube docker-env)`, your local Docker client talks to Minikube's daemon. Images built this way are immediately available to the cluster — no push/pull needed.

**Important:** Always run `eval $(minikube docker-env)` in each terminal session before building.

---

## 5. Deploying the Stack

### 5.1 Start Minikube

```bash
# Standard start (enough for dev)
minikube start --cpus 4 --memory 8192 --disk-size 20g

# For on-premises production-like (more resources)
minikube start \
  --cpus 8 \
  --memory 16384 \
  --disk-size 50g \
  --driver kvm2 \
  --kubernetes-version v1.31.0

# Enable critical addons
minikube addons enable ingress
minikube addons enable metrics-server
minikube addons enable dashboard
minikube addons enable metallb  # For LoadBalancer-type services

# Optional addons
minikube addons enable logviewer
minikube addons enable registry  # If you want a local registry
```

### 5.2 Create Namespace & Apply Manifests

```bash
# Create namespace
kubectl apply -f base/namespace.yaml

# Deploy infrastructure (PostgreSQL, Redis, Kafka/Zookeeper)
kubectl apply -f infrastructure/ -n mytutorial

# Wait for infra to be ready
kubectl wait --for=condition=ready pod -l app=postgres -n mytutorial --timeout=120s
kubectl wait --for=condition=ready pod -l app=redis -n mytutorial --timeout=60s
kubectl wait --for=condition=ready pod -l app=kafka -n mytutorial --timeout=120s

# Deploy application with kustomize
kustomize build overlays/dev | kubectl apply -n mytutorial -f -

# Wait for all pods
kubectl wait --for=condition=ready pod -l tier=backend -n mytutorial --timeout=300s
```

### 5.3 Deploy Script

```bash
#!/bin/bash
# scripts/deploy-local.sh
set -euo pipefail

ENV=${1:-dev}
NAMESPACE=${NAMESPACE:-mytutorial}

echo "=== Deploying MyTutorial to Minikube (${ENV}) ==="

# 1. Start minikube if not running
if ! minikube status 2>/dev/null | grep -q "Running"; then
  echo "Starting Minikube..."
  minikube start --cpus 4 --memory 8192
  minikube addons enable ingress
  minikube addons enable metrics-server
fi

# 2. Point Docker to minikube
eval $(minikube docker-env)

# 3. Build images
echo "--- Building images ---"
cd ../../backend
for svc in eureka-server auth-service grades-service notification-service api-gateway; do
  echo "Building $svc..."
  docker build -f "$svc/Dockerfile" -t "mytutorial/$svc:latest" . 2>&1 | tail -1
done
cd ../"deploy-local"

# 4. Create namespace
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# 5. Deploy infrastructure
echo "--- Deploying infrastructure ---"
kubectl apply -f infrastructure/ -n "${NAMESPACE}"

# 6. Wait for infrastructure
echo "--- Waiting for infrastructure ---"
kubectl wait --for=condition=ready pod -l app=postgres -n "${NAMESPACE}" --timeout=120s 2>/dev/null || echo "Postgres not ready yet, continuing..."
kubectl wait --for=condition=ready pod -l app=redis -n "${NAMESPACE}" --timeout=60s 2>/dev/null || echo "Redis not ready yet, continuing..."

# 7. Deploy application
echo "--- Deploying application (${ENV}) ---"
kustomize build "overlays/${ENV}" | kubectl apply -n "${NAMESPACE}" -f -

# 8. Wait for application
echo "--- Waiting for application ---"
for svc in eureka-server auth-service grades-service notification-service api-gateway; do
  kubectl rollout status "deployment/$svc" -n "${NAMESPACE}" --timeout=180s 2>/dev/null || echo "$svc rollout timed out"
done

# 9. Create ingress
kubectl apply -f base/ingress.yaml -n "${NAMESPACE}" 2>/dev/null || true

echo ""
echo "=== Deployment complete ==="
echo ""
echo "Access the application:"
echo "  kubectl port-forward -n ${NAMESPACE} service/api-gateway 8080:80"
echo "  curl http://localhost:8080/actuator/health"
echo ""
echo "Or with minikube tunnel (LoadBalancer):"
echo "  minikube tunnel"
echo "  Then access at: http://localhost:80"
```

### 5.4 Verify Deployment

```bash
# Check all resources
kubectl get pods -n mytutorial
kubectl get services -n mytutorial
kubectl get deployments -n mytutorial
kubectl get hpa -n mytutorial
kubectl get pvc -n mytutorial

# Check logs of a specific service
kubectl logs -n mytutorial -l app=auth-service --tail=50

# Check events
kubectl get events -n mytutorial --sort-by='.lastTimestamp'
```

---

## 6. Accessing Services

### 6.1 Port-Forward (Simplest — Development)

```bash
# API Gateway
kubectl port-forward -n mytutorial service/api-gateway 8080:80

# Then open: http://localhost:8080
# Test: curl http://localhost:8080/actuator/health

# Access any service directly:
kubectl port-forward -n mytutorial service/auth-service 8081:8081
kubectl port-forward -n mytutorial service/eureka-server 8761:8761
kubectl port-forward -n mytutorial service/opensearch-dashboards 5601:5601
```

### 6.2 Minikube Service (One-Liner URLs)

```bash
# Open API Gateway in default browser
minikube service api-gateway -n mytutorial

# Get the URL
minikube service api-gateway -n mytutorial --url
```

### 6.3 Minikube Tunnel (LoadBalancer Mode)

If you set `api-gateway` service type to `LoadBalancer`, use:

```bash
# In a separate terminal:
minikube tunnel

# Then access at: http://localhost:80
```

### 6.4 Ingress (NGINX — Recommended)

```bash
# Enable ingress addon (already done at start)
minikube addons enable ingress

# Get minikube IP
MINIKUBE_IP=$(minikube ip)

# Add to /etc/hosts (Linux/macOS) or C:\Windows\System32\drivers\etc\hosts (Windows)
echo "$MINIKUBE_IP api.mytutorial.local" | sudo tee -a /etc/hosts

# Now access: http://api.mytutorial.local
# Or:      curl http://api.mytutorial.local/actuator/health
```

The Ingress resource is defined in `base/ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: api-gateway
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
    - host: api.mytutorial.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: api-gateway
                port:
                  number: 80
```

### 6.5 Service URLs Summary

| Service | Port-Forward | Minikube Service | Ingress |
|---------|-------------|------------------|---------|
| API Gateway | `localhost:8080` | `minikube service api-gateway` | `api.mytutorial.local` |
| Eureka Dashboard | `localhost:8761` | `minikube service eureka-server` | — |
| Auth Service | `localhost:8081` | `minikube service auth-service` | — |
| OpenSearch Dashboards | `localhost:5601` | `minikube service opensearch-dashboards` | — |
| Prometheus | `localhost:9090` | `minikube service prometheus` | — |
| Minikube Dashboard | — | `minikube dashboard` | — |

### 6.6 Self-Signed SSL (Optional)

```bash
# Install mkcert
# Linux: sudo apt install mkcert
# macOS: brew install mkcert
# Windows: choco install mkcert

mkcert -install
mkcert api.mytutorial.local

# Create TLS secret
kubectl create secret tls mytutorial-tls \
  --cert=api.mytutorial.local.pem \
  --key=api.mytutorial.local-key.pem \
  -n mytutorial
```

---

## 7. Environment Overlays

### 7.1 Dev (Default)

```yaml
# overlays/dev/kustomization.yaml
# - 1 replica for all services
# - HPA min=1, max=3
# - Minimal resource requests
# - Single-node friendly
```

```bash
kustomize build overlays/dev | kubectl apply -n mytutorial -f -
```

### 7.2 Staging

```yaml
# overlays/staging/kustomization.yaml
# - 2 replicas
# - Medium resource requests
# - HPA min=2, max=5
# - Simulates multi-node behavior
```

```bash
kustomize build overlays/staging | kubectl apply -n mytutorial -f -
```

### 7.3 Production-Like (On-Premises)

```yaml
# overlays/prod/kustomization.yaml
# - 3 replicas
# - Full resource limits
# - HPA min=3, max=10
# - Resource quotas applied
# - PDBs enforced
```

```bash
kustomize build overlays/prod | kubectl apply -n mytutorial -f -
```

---

## 8. Monitoring & Observability

### 8.1 Minikube Dashboard

```bash
# Built-in Kubernetes dashboard
minikube dashboard
```

### 8.2 Prometheus Stack

Deploy Prometheus with pod discovery:

```bash
# Deploy Prometheus
kubectl apply -f infrastructure/prometheus.yaml -n mytutorial

# Access
kubectl port-forward -n mytutorial service/prometheus 9090:9090
# Open: http://localhost:9090
```

**Available metrics** (exposed by each service at `/actuator/prometheus`):

| Metric | Query Example |
|--------|---------------|
| JVM Heap | `jvm_memory_used_bytes{area="heap"}` |
| CPU | `process_cpu_usage{app="auth-service"}` |
| HTTP Requests | `rate(http_server_requests_seconds_count[5m])` |
| GC Pause | `jvm_gc_pause_seconds_sum` |
| Threads | `jvm_threads_live_threads` |
| DB Connections | `hikaricp_connections_active` |

### 8.3 Grafana

```bash
# Deploy Grafana
kubectl apply -f infrastructure/grafana.yaml -n mytutorial

# Access
kubectl port-forward -n mytutorial service/grafana 3000:3000
# Open: http://localhost:3000 (admin/admin)

# Import the included JVM dashboard:
# 1. Go to Dashboards → Import
# 2. Upload base/dashboards/jvm-micrometer.json
# 3. Select Prometheus datasource
```

### 8.4 ELK Stack (OpenSearch + Logstash)

```bash
# Deploy ELK
kubectl apply -f infrastructure/elk.yaml -n mytutorial

# Access OpenSearch Dashboards
kubectl port-forward -n mytutorial service/opensearch-dashboards 5601:5601
# Open: http://localhost:5601
```

### 8.5 Logs

```bash
# View logs for a specific service
kubectl logs -n mytutorial -l app=auth-service --tail=100 -f

# View logs across all services
kubectl logs -n mytutorial -l tier=backend --tail=20

# Using stern (for multi-pod log tailing)
# brew install stern  or  download from GitHub
stern auth-service -n mytutorial

# View Minikube node logs
minikube logs | tail -50
```

### 8.6 Resource Usage

```bash
# Top pods by CPU/memory
kubectl top pods -n mytutorial

# Top nodes
kubectl top nodes

# View Minikube VM resource usage
minikube ssh -- top
```

---

## 9. Managing the Cluster

### 9.1 Starting & Stopping

```bash
# Start (with specific resources)
minikube start --cpus 4 --memory 8192 --disk-size 20g

# Stop (preserves cluster state)
minikube stop

# Delete (destroys everything, including images and PVCs)
minikube delete

# Pause/Unpause (freezes VMs without losing state)
minikube pause
minikube unpause
```

### 9.2 Configuration Profiles

```bash
# Create a production-like profile
minikube start -p mytutorial-prod \
  --cpus 8 --memory 16384 --disk-size 50g \
  --driver kvm2 \
  --container-runtime containerd

# List profiles
minikube profile list

# Switch between profiles
minikube profile mytutorial-prod

# Stop a specific profile
minikube stop -p mytutorial-prod
```

### 9.3 Scaling (Minikube Single-Node)

Since Minikube runs a single node, HPA will create multiple pods on that one node:

```bash
# Create additional load to trigger HPA
kubectl run load-test --image=alpine --rm -it --restart=Never -- \
  sh -c "apk add curl; while true; do curl -s http://auth-service:8081/actuator/health; done"

# Watch HPA
kubectl get hpa -n mytutorial -w

# Manual scale (if HPA is not configured)
kubectl scale deployment/auth-service --replicas=5 -n mytutorial
```

### 9.4 Rolling Updates

```bash
# Rebuild a service image, then restart
eval $(minikube docker-env)
cd ../../backend
docker build -f auth-service/Dockerfile -t mytutorial/auth-service:latest .
cd ../"deploy-local"
kubectl rollout restart deployment/auth-service -n mytutorial

# Monitor rollout
kubectl rollout status deployment/auth-service -n mytutorial

# Rollback
kubectl rollout undo deployment/auth-service -n mytutorial
```

### 9.5 Node Maintenance (Simulated)

```bash
# Drain (simulates node maintenance)
kubectl drain minikube --ignore-daemonsets

# Uncordon
kubectl uncordon minikube
```

### 9.6 SSH into Minikube

```bash
# SSH into the Minikube VM
minikube ssh

# Common commands inside:
docker ps                    # See all running containers
journalctl -u kubelet -f     # Kubelet logs
df -h                       # Disk usage
free -h                     # Memory usage
top                         # Process monitor
```

### 9.7 Backup & Restore

```bash
# Backup Kubernetes resources
kubectl get all -n mytutorial -o yaml > mytutorial-backup.yaml
kubectl get pvc -n mytutorial -o yaml >> mytutorial-backup.yaml
kubectl get configmaps,secrets -n mytutorial -o yaml >> mytutorial-backup.yaml

# Save Docker images (export from minikube to tar)
eval $(minikube docker-env)
docker save mytutorial/auth-service:latest -o auth-service.tar
docker save mytutorial/grades-service:latest -o grades-service.tar
# ...

# Restore from backup
kubectl apply -f mytutorial-backup.yaml

# Or redeploy with build-all + deploy-local
```

### 9.8 Upgrading Minikube

```bash
# Check current version
minikube version

# Update minikube to latest
# Linux: curl -LO ... && sudo install minikube-linux-amd64 /usr/local/bin/minikube
# macOS: brew upgrade minikube
# Windows: choco upgrade minikube

# Update Kubernetes version in existing cluster
minikube start --kubernetes-version v1.31.0
```

---

## 10. Persistence & Storage

### 10.1 Minikube Storage Classes

```bash
# Minikube provides a 'standard' StorageClass backed by hostPath
kubectl get storageclass

# For on-premises with better durability, use:
# - hostPath (default, lost on minikube delete)
# - NFS (if you have an NFS server)
# - local-path-provisioner (Rancher)
```

### 10.2 Persistent Volumes

The infrastructure manifests use PVCs:

| Service | Storage | PVC Name | Access Mode |
|---------|---------|----------|-------------|
| PostgreSQL | 5 GiB | postgres-data | ReadWriteOnce |
| Kafka | 5 GiB | kafka-data | ReadWriteOnce |
| Zookeeper | 2 GiB | zookeeper-data | ReadWriteOnce |

```yaml
# PVCs are defined in the StatefulSet templates (infrastructure/postgres.yaml)
# They survive minikube stop/start but NOT minikube delete
```

### 10.3 Data Persistence After Minikube Delete

To survive a `minikube delete`, mount a host directory:

```bash
# Start minikube with a bind mount for persistent data
minikube start \
  --cpus 4 --memory 8192 \
  --mount-string="/data/mytutorial:/data" \
  --mount

# Then configure your PostgreSQL to use /data as data directory
# (Requires custom Docker image or initContainer)
```

### 10.4 Recreate After Full Reset

```bash
# Full reset
minikube delete
minikube start --cpus 4 --memory 8192
minikube addons enable ingress
minikube addons enable metrics-server

# Redeploy
./scripts/build-all.sh
./scripts/deploy-local.sh dev
```

---

## 11. CI/CD for Local Deployments

### 11.1 Local CI/CD with Docker Compose

For a fully local pipeline, use **DinD (Docker-in-Docker)**:

```yaml
version: '3'
services:
  jenkins:
    image: jenkins/jenkins:lts
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./jenkins_home:/var/jenkins_home
    ports:
      - 8080:8080
      - 50000:50000
```

Jenkins pipeline:

```groovy
pipeline {
    agent any
    environment {
        MINIKUBE_IP = sh(script: 'minikube ip', returnStdout: true).trim()
    }
    stages {
        stage('Test') {
            steps {
                dir('backend') {
                    sh 'mvn -B test -q'
                }
            }
        }
        stage('Build Images') {
            steps {
                sh 'eval $(minikube docker-env)'
                dir('backend') {
                    script {
                        def services = ['eureka-server', 'auth-service', 'grades-service', 'notification-service', 'api-gateway']
                        services.each { svc ->
                            sh "docker build -f ${svc}/Dockerfile -t mytutorial/${svc}:latest ."
                        }
                    }
                }
            }
        }
        stage('Deploy') {
            steps {
                dir('"deploy-local"') {
                    sh 'kustomize build overlays/dev | kubectl apply -n mytutorial -f -'
                }
            }
        }
        stage('Verify') {
            steps {
                sh 'kubectl rollout status deployment/auth-service -n mytutorial --timeout=120s'
            }
        }
    }
    post {
        failure {
            echo 'Deployment failed! Check logs.'
        }
    }
}
```

### 11.2 GitLab CI/CD

```yaml
# .gitlab-ci.yml
stages:
  - test
  - build
  - deploy

variables:
  NAMESPACE: mytutorial

test:
  stage: test
  image: maven:3.9-eclipse-temurin-21
  script:
    - cd backend && mvn -B test -q

build:
  stage: build
  image: docker:24
  before_script:
    - apk add kubectl minikube
    - minikube start --driver=none  # For GitLab Runner on same host
    - eval $(minikube docker-env)
  script:
    - cd backend
    - for svc in eureka-server auth-service grades-service notification-service api-gateway; do
        docker build -f "$svc/Dockerfile" -t "mytutorial/$svc:latest" .;
      done

deploy:
  stage: deploy
  script:
    - cd "deploy-local"
    - kustomize build overlays/dev | kubectl apply -n $NAMESPACE -f -
    - for svc in eureka-server auth-service grades-service notification-service api-gateway; do
        kubectl rollout status "deployment/$svc" -n $NAMESPACE --timeout=120s;
      done
```

### 11.3 GitHub Actions (Self-Hosted Runner)

```yaml
# .github/workflows/deploy-local.yml
name: Deploy to Local Minikube

on:
  push:
    branches: [main, develop]
    paths:
      - 'backend/**'

jobs:
  deploy:
    runs-on: self-hosted  # Must have minikube installed
    steps:
      - uses: actions/checkout@v4

      - name: Start Minikube
        run: |
          minikube start --cpus 4 --memory 8192 --driver=none
          minikube addons enable ingress
          minikube addons enable metrics-server

      - name: Build images
        run: |
          eval $(minikube docker-env)
          cd backend
          for svc in eureka-server auth-service grades-service notification-service api-gateway; do
            docker build -f "$svc/Dockerfile" -t "mytutorial/$svc:latest" .
          done

      - name: Deploy
        run: |
          cd "deploy-local"
          kubectl apply -f base/namespace.yaml
          kubectl apply -f infrastructure/ -n mytutorial
          kustomize build overlays/dev | kubectl apply -n mytutorial -f -

      - name: Health check
        run: |
          kubectl rollout status deployment/api-gateway -n mytutorial --timeout=120s
          kubectl port-forward -n mytutorial service/api-gateway 8080:80 &
          sleep 5
          curl -sf http://localhost:8080/actuator/health
```

---

## 12. Troubleshooting

### 12.1 Common Minikube Errors

| Error | Cause | Fix |
|-------|-------|-----|
| `Unable to find image` | Image not in minikube's Docker | Run `eval $(minikube docker-env)` before building |
| `Exceeded resources` | Not enough CPU/memory | `minikube stop` then `minikube start --cpus 8 --memory 16384` |
| `IP address exhausted` | Too many services in a small cluster | Increase service CIDR: `minikube start --service-cluster-ip-range 10.96.0.0/12` |
| `No external IP` | minikube tunnel not running | Run `minikube tunnel` in another terminal |
| `context deadline exceeded` | Minikube VM overloaded | Increase resources or reduce replicas |
| `Pod stuck in ContainerCreating` | Image pull or storage issue | `kubectl describe pod` to see details |
| `Ingress not working` | Ingress addon not enabled | `minikube addons enable ingress` |

### 12.2 Minikube Won't Start

```bash
# Check logs
minikube logs | tail -50

# Try different driver
minikube start --driver=docker    # Docker driver (works everywhere)
minikube start --driver=kvm2      # Linux KVM (best performance)
minikube start --driver=virtualbox # VirtualBox
minikube start --driver=hyperv    # Windows Hyper-V

# Delete and recreate
minikube delete
minikube start --cpus 4 --memory 8192
```

### 12.3 Pods Won't Start

```bash
# Check pod details
kubectl describe pod auth-service-xxxxx -n mytutorial

# Check cluster events
kubectl get events -n mytutorial --sort-by='.lastTimestamp'

# Check minikube VM
minikube ssh -- free -m
minikube ssh -- df -h
minikube ssh -- docker ps -a | grep auth-service
```

### 12.4 Image Build Fails

```bash
# Ensure docker-env is set
eval $(minikube docker-env)
docker info  # Should show minikube's Docker

# If "docker: command not found":
# Install Docker first

# If Docker daemon not running:
minikube ssh -- sudo systemctl start docker
```

### 12.5 Out of Disk Space

```bash
# Check disk usage
minikube ssh -- df -h

# Clean up unused images
eval $(minikube docker-env)
docker system prune -af

# Clean up old builds
minikube ssh -- docker system prune -af

# Delete and recreate with larger disk
minikube delete
minikube start --disk-size 50g
```

### 12.6 Networking

```bash
# Test DNS
kubectl run dns-test --image=alpine --rm -it -n mytutorial -- nslookup auth-service

# Test pod-to-service connectivity
kubectl run curl-test --image=curlimages/curl --rm -it -n mytutorial -- \
  curl -sv http://auth-service:8081/actuator/health

# Test external connectivity
kubectl run net-test --image=nicolaka/netshoot --rm -it -n mytutorial -- curl -sv http://google.com

# Restart DNS
kubectl rollout restart -n kube-system deployment/coredns
```

### 12.7 Ingress Issues

```bash
# Check NGINX controller logs
kubectl logs -n ingress-nginx deployment/ingress-nginx-controller

# Check ingress resource
kubectl describe ingress api-gateway -n mytutorial

# Verify /etc/hosts entry
grep mytutorial.local /etc/hosts

# Re-add ingress addon
minikube addons disable ingress
minikube addons enable ingress
```

### 12.8 Quick Diagnostic Commands

```bash
# ═══════════════════════════════════════════════════
# MINIKUBE STATUS
# ═══════════════════════════════════════════════════
minikube status
minikube ip
minikube version
minikube addons list

# ═══════════════════════════════════════════════════
# CLUSTER STATUS
# ═══════════════════════════════════════════════════
kubectl cluster-info
kubectl get nodes -o wide
kubectl get pods -n mytutorial -o wide
kubectl get services -n mytutorial
kubectl get deployments -n mytutorial
kubectl get hpa -n mytutorial
kubectl get pvc -n mytutorial
kubectl top pods -n mytutorial
kubectl top nodes

# ═══════════════════════════════════════════════════
# APPLICATION LOGS
# ═══════════════════════════════════════════════════
kubectl logs -n mytutorial -l app=auth-service --tail=20
kubectl logs -n mytutorial -l app=api-gateway --tail=20
kubectl logs -n mytutorial -l tier=backend --tail=10

# ═══════════════════════════════════════════════════
# EVENTS
# ═══════════════════════════════════════════════════
kubectl get events -n mytutorial --sort-by='.lastTimestamp'

# ═══════════════════════════════════════════════════
# IMAGES IN MINIKUBE
# ═══════════════════════════════════════════════════
eval $(minikube docker-env)
docker images | grep mytutorial
```

---

## Appendix: File Reference

### Directory Structure

```
deploy-local/
├── README.md                          ← This file (complete guide)
├── base/
│   ├── namespace.yaml                 ← mytutorial namespace
│   ├── configmaps.yaml               ← Shared + per-service env vars
│   ├── deployments.yaml              ← All 5 service deployments
│   ├── services.yaml                 ← Stable network endpoints
│   ├── hpas.yaml                     ← Auto-scaling rules
│   ├── pdbs.yaml                     ← Disruption budgets
│   ├── network-policies.yaml         ← Network traffic rules
│   ├── ingress.yaml                  ← NGINX ingress for local access
│   └── kustomization.yaml            ← Composes all base resources
├── overlays/
│   ├── dev/
│   │   ├── kustomization.yaml        ← 1 replica, HPA 1-3, small resources
│   │   └── patches.yaml              ← Resource tuning for local dev
│   ├── staging/
│   │   └── kustomization.yaml        ← 2 replicas, medium resources
│   └── prod/
│       └── kustomization.yaml        ← 3 replicas, full limits, HPA 3-10
├── infrastructure/
│   ├── postgres.yaml                 ← PostgreSQL StatefulSet + PVC (5Gi)
│   ├── redis.yaml                    ← Redis Deployment
│   ├── kafka.yaml                    ← Zookeeper + Kafka StatefulSets
│   ├── prometheus.yaml               ← Prometheus with pod auto-discovery
│   ├── grafana.yaml                  ← Grafana with datasource provisioning
│   └── elk.yaml                      ← OpenSearch + Logstash + Dashboards
└── scripts/
    ├── build-all.sh                  ← Build all images into minikube
    ├── deploy-local.sh               ← Full deploy: build → infra → app
    ├── rebuild-service.sh            ← Rebuild and restart a single service
    └── reset-local.sh                ← Full reset: delete minikube → recreate
```

### Key Differences from Cloud `k8s/` Directory

| Aspect | `k8s/` (Cloud) | `deploy-local/` (Minikube) |
|--------|----------------|-----------------------------|
| **Image registry** | ECR/ACR/GCR URL | `mytutorial/svc:latest` (local) |
| **Image pull policy** | `Always` | `IfNotPresent` (or `Never`) |
| **Ingress class** | `alb` / `gce` / `azure-application-gateway` | `nginx` |
| **Storage class** | `ebs-csi` / `pd-ssd` / `managed-csi` | `standard` (hostPath) |
| **Service type** | `LoadBalancer` | `ClusterIP` + `port-forward` |
| **Resources** | Production-sized | Minimal (dev-friendly) |
| **HPA replicas** | 2-10 / 3-15 | 1-3 / 1-5 |
| **Monitoring** | AMP / AMG / CloudWatch | Built-in Prometheus + Grafana |
| **DNS** | Route 53 / Cloud DNS | `/etc/hosts` |
| **SSL** | ACM / Google-managed | Self-signed with mkcert |
| **Deployment** | CI/CD pipeline | `./scripts/deploy-local.sh` |

---

## References

- [Minikube Documentation](https://minikube.sigs.k8s.io/docs/)
- [Minikube Start Command Reference](https://minikube.sigs.k8s.io/docs/commands/start/)
- [Minikube Addons](https://minikube.sigs.k8s.io/docs/handbook/addons/)
- [Kubernetes Dashboard](https://kubernetes.io/docs/tasks/access-application-cluster/web-ui-dashboard/)
- [Kustomize User Guide](https://kubectl.docs.kubernetes.io/guides/)
- [NGINX Ingress Controller](https://kubernetes.github.io/ingress-nginx/)
- [Prometheus on Kubernetes](https://prometheus.io/docs/prometheus/latest/configuration/configuration/#kubernetes_sd_config)
- [OpenSearch on Kubernetes](https://opensearch.org/docs/latest/install-and-configure/install-opensearch/kubernetes/)
- [mkcert - Local SSL](https://github.com/FiloSottile/mkcert)