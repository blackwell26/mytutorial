# Deploying & Managing Containerized Applications Locally with Minishift

This is a self-contained deployment package for running the MyTutorial microservices stack on **Minishift** (the local OpenShift 3.x development environment). It uses OpenShift-native resources — DeploymentConfigs, ImageStreams, Routes, Builds, and SCC — while keeping the cluster on your local machine.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Minishift vs Minikube vs Full OpenShift](#2-minishift-vs-minikube-vs-full-openshift)
3. [Prerequisites & Installation](#3-prerequisites--installation)
4. [Quick Start](#4-quick-start)
5. [Building Images into Minishift](#5-building-images-into-minishift)
6. [Deploying the Stack](#6-deploying-the-stack)
7. [Accessing Services](#7-accessing-services)
8. [Environment Overlays](#8-environment-overlays)
9. [Monitoring & Observability](#9-monitoring--observability)
10. [Managing the Cluster](#10-managing-the-cluster)
11. [Persistence & Storage](#11-persistence--storage)
12. [Rebuilding a Single Service](#12-rebuilding-a-single-service)
13. [Resetting the Cluster](#13-resetting-the-cluster)
14. [Troubleshooting](#14-troubleshooting)

---

## 1. Architecture Overview

This package deploys the full MyTutorial stack on a **single-node Minishift VM** running on your local machine:

```
                           ┌──────────────────────┐
                           │  OpenShift Router    │
                           │  (HAProxy)           │
                           │  *.nip.io            │
                           └──────────┬───────────┘
                                      │
                           ┌──────────▼───────────┐
                           │       Route          │
                           │  api-gateway-...nip.io│
                           │  Edge TLS             │
                           └──────────┬───────────┘
                                      │
                    ┌─────────────────┼─────────────────┐
                    │                 │                  │
              ┌─────▼──────┐   ┌─────▼──────┐   ┌───────▼──────┐
              │ api-       │   │ auth-      │   │ grades-      │
              │ gateway    │   │ service    │   │ service      │
              │ :8080      │   │ :8081      │   │ :8082        │
              │ 1-3 pods   │   │ 1-3 pods   │   │ 1-3 pods     │
              │ DC         │   │ DC         │   │ DC           │
              └─────┬──────┘   └─────┬──────┘   └───────┬──────┘
                    │                │                   │
              ┌─────▼──────┐        │             ┌─────▼──────┐
              │ eureka-    │        │             │ notifica-  │
              │ server     │        │             │ tion-svc   │
              │ :8761      │        │             │ :8083      │
              │ 1 pod      │        │             │ 1-2 pods   │
              └────────────┘        │             └─────┬──────┘
                                    │                   │
           ┌────────────────────────┼───────────────────┼──────────────────┐
           │                        │                   │                  │
     ┌─────▼──────┐          ┌──────▼──────┐     ┌──────▼──────┐   ┌──────▼──────┐
     │ PostgreSQL │          │ Redis       │     │ Kafka       │   │ Monitoring  │
     │ StatefulSet│          │ Deployment  │     │ StatefulSet │   │ Prometheus  │
     │ 5Gi PVC    │          │             │     │ 5Gi PVC     │   │ Grafana     │
     └────────────┘          └─────────────┘     └─────────────┘   │ OpenSearch  │
                                                                    └─────────────┘
```

---

## 2. Minishift vs Minikube vs Full OpenShift

| Feature | Minishift | Minikube | Full OpenShift 4.x |
|---------|-----------|----------|---------------------|
| **Based on** | OpenShift 3.x (OKD) | Upstream Kubernetes | OpenShift 4.x (OKD) |
| **CLI** | `oc` (primary), `kubectl` | `kubectl` | `oc` (primary) |
| **Routing** | Routes (HAProxy) + nip.io | Ingress (NGINX) | Routes (HAProxy) |
| **Images** | Build + push to internal registry | Build into Docker daemon | BuildConfig or push to internal registry |
| **Deployments** | DeploymentConfig (with ImageChange triggers) | Deployment | Deployment + DeploymentConfig |
| **Registry** | Internal OpenShift registry (`:5000`) | Docker daemon (no registry) | Internal OpenShift registry |
| **Security** | SCC (Security Context Constraints) | Pod Security Standards | SCC |
| **ImageStreams** | Yes | No | Yes |
| **Resource** | 1 VM (driver-dependent) | 1 VM | Multi-node cluster (VMs/bare-metal) |
| **Driver** | HyperKit, VirtualBox, KVM | Docker, KVM, VirtualBox, HyperKit | Cloud infrastructure |
| **Use case** | Local OpenShift dev | Local K8s dev | Production OpenShift |

**Why use Minishift?** If your production target is OpenShift, Minishift gives you the closest local development experience — same `oc` CLI, same DeploymentConfig triggers, same SCC model, same Routes and internal registry workflow.

---

## 3. Prerequisites & Installation

### System Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| **CPU** | 4 cores | 8 cores |
| **Memory** | 8 GB | 16 GB |
| **Disk** | 20 GB free | 50 GB free (SSD) |
| **OS** | Linux, macOS | Linux (Ubuntu 22.04+) |

### Install Minishift

```bash
# ── Linux (KVM driver) ──
curl -LO https://github.com/minishift/minishift/releases/latest/download/minishift-linux-amd64.tgz
tar xzf minishift-linux-amd64.tgz
sudo mv minishift-*/minishift /usr/local/bin/

# ── macOS ──
brew install minishift

# ── Windows ──
# Download from: https://github.com/minishift/minishift/releases
```

### Install Other Dependencies

```bash
# ── OpenShift CLI (oc) ──
# Linux:
curl -LO https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-client-linux.tar.gz
tar xzf openshift-client-linux.tar.gz
sudo mv oc kubectl /usr/local/bin/

# macOS:
brew install openshift-cli

# ── kustomize ──
curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
sudo mv kustomize /usr/local/bin/

# ── Docker ──
# Linux: sudo apt install docker.io
# macOS: brew install docker
```

### Verify Installation

```bash
minishift version
oc version
docker --version
kustomize version
```

---

## 4. Quick Start

```bash
# 1. Start Minishift
minishift start --cpus 4 --memory 8192 --disk-size 20g

# 2. Get the console URL and login
minishift console

# 3. Log in via CLI (use token from console)
oc login $(minishift ip):8443 --username=developer --password=developer

# 4. Build all images and deploy
./scripts/deploy-minishift.sh dev

# 5. Watch pods come online
oc get pods -n mytutorial -w

# 6. Test the health endpoint
oc get routes -n mytutorial
curl -k https://api-gateway-mytutorial.$(minishift ip).nip.io/actuator/health

# 7. Open Minishift Console
minishift console
```

---

## 5. Building Images into Minishift

### 5.1 How Image Building Works in Minishift

Unlike Minikube (where you load images into the Docker daemon directly), Minishift uses an **internal OpenShift image registry**. The build flow is:

```
Host Docker build → Tag for registry → Push to Minishift's internal registry
                                                                        ↓
                                                              OpenShift ImageStream
                                                                        ↓
                                                         DeploymentConfig triggers
                                                                        ↓
                                                              Pod restarts with new image
```

### 5.2 Build All Services

```bash
# From the deploy-minishift directory:
./scripts/build-all.sh
```

This script:
1. Builds all 5 service images (`eureka-server`, `auth-service`, `grades-service`, `notification-service`, `api-gateway`) using host Docker
2. Tags them for the Minishift internal registry at `$(minishift ip):5000`
3. Logs into the registry using your OpenShift token
4. Pushes images to the registry
5. Updates ImageStream tags so DeploymentConfigs auto-deploy

### 5.3 Manual Build for a Single Service

```bash
# Build just one service and push to Minishift
cd ../../backend
docker build -f auth-service/Dockerfile -t mytutorial/auth-service:latest .

REGISTRY="$(minishift ip):5000"
docker tag mytutorial/auth-service:latest "${REGISTRY}/mytutorial/auth-service:latest"
docker push "${REGISTRY}/mytutorial/auth-service:latest"
oc tag --source=docker "${REGISTRY}/mytutorial/auth-service:latest" auth-service:latest -n mytutorial
```

---

## 6. Deploying the Stack

### 6.1 One-Command Deploy

```bash
# Deploy to dev environment
./scripts/deploy-minishift.sh dev

# Deploy to staging
./scripts/deploy-minishift.sh staging

# Deploy to production overlay
./scripts/deploy-minishift.sh prod
```

The deploy script automates:
1. **Minishift checks** — Starts Minishift if not running, verifies `oc` login
2. **Project setup** — Creates `mytutorial` project if needed
3. **Service account** — Creates `mytutorial-sa` with `anyuid` SCC permission (required for Java/JRE containers that need to bind to ports)
4. **ImageStreams** — Creates `ImageStream` resources so `DeploymentConfig` ImageChange triggers work
5. **Build** — Runs `build-all.sh` to build + push images
6. **Infrastructure** — Deploys Postgres (StatefulSet, 5Gi PVC), Redis (Deployment), Kafka + Zookeeper (StatefulSet)
7. **Application** — Uses `kustomize build overlays/<env>` to deploy all services with overlay patches
8. **Monitoring** — Deploys Prometheus, Grafana, OpenSearch/Logstash/Dashboards
9. **Routes** — Creates OpenShift Routes for external access via `nip.io`
10. **Rollout wait** — Waits for each DeploymentConfig to complete rollout

### 6.2 Step-by-Step (Manual)

```bash
# 1. Ensure Minishift is running
minishift status

# 2. Log in
oc login -u developer -p developer

# 3. Create project
oc new-project mytutorial

# 4. Create ImageStreams
oc apply -f base/imagestreams.yaml -n mytutorial

# 5. Build images
./scripts/build-all.sh

# 6. Deploy infrastructure
oc apply -f infrastructure/ -n mytutorial

# 7. Wait for Postgres and Redis
oc wait --for=condition=ready pod -l app=postgres -n mytutorial --timeout=120s
oc wait --for=condition=ready pod -l app=redis -n mytutorial --timeout=60s

# 8. Deploy application
kustomize build overlays/dev | oc apply -n mytutorial -f -

# 9. Wait for services
for svc in eureka-server auth-service grades-service notification-service api-gateway; do
  oc rollout status "dc/$svc" -n mytutorial --timeout=180s
done

# 10. Create routes
oc create route edge api-gateway --service=api-gateway --port=8080 -n mytutorial
```

---

## 7. Accessing Services

### 7.1 Via Routes

Minishift automatically assigns `*.nip.io` wildcard DNS pointing to the Minishift IP:

```bash
# List all routes
oc get routes -n mytutorial

# Example output:
# NAME             HOST/PORT                                                   ...
# api-gateway      api-gateway-mytutorial.192.168.42.100.nip.io
# eureka-server    eureka-server-mytutorial.192.168.42.100.nip.io

# Access the API Gateway
curl -k https://api-gateway-mytutorial.$(minishift ip).nip.io/actuator/health

# Access Eureka Dashboard
curl -k https://eureka-server-mytutorial.$(minishift ip).nip.io/
```

| Service | Route URL |
|---------|-----------|
| **API Gateway** | `https://api-gateway-mytutorial.<minishift-ip>.nip.io` |
| **Eureka Server** | `https://eureka-server-mytutorial.<minishift-ip>.nip.io` |
| **Auth Service** | `https://auth-service-mytutorial.<minishift-ip>.nip.io` |
| **Prometheus** | `https://prometheus-mytutorial.<minishift-ip>.nip.io` |
| **Grafana** | `https://grafana-mytutorial.<minishift-ip>.nip.io` |

Routes use **edge TLS termination** — the Minishift router handles HTTPS, and traffic inside the cluster is plain HTTP.

### 7.2 Via Port-Forwarding

```bash
# API Gateway (port 80 → 8080)
oc port-forward service/api-gateway 8080:80 -n mytutorial

# Prometheus
oc port-forward service/prometheus 9090:9090 -n mytutorial

# Grafana
oc port-forward service/grafana 3000:3000 -n mytutorial
```

### 7.3 OpenShift Web Console

```bash
minishift console
# Opens the OpenShift web UI in your browser
```

---

## 8. Environment Overlays

Three environment overlays control replica counts and HPA settings:

| Overlay | Replicas (default) | HPA min/max | Use case |
|---------|-------------------|-------------|----------|
| **dev** | All services: 1 | 1–3 | Local development, minimal resource usage |
| **staging** | Core services: 2, Others: 1 | 2–5 | Pre-prod testing |
| **prod** | Core: 3, Infra: 2 | 3–10 | Production-like local test |

Core services (auto-scaled): `auth-service`, `grades-service`, `api-gateway`
Infra services: `eureka-server`, `notification-service`

---

## 9. Monitoring & Observability

| Component | Description | Access |
|-----------|-------------|--------|
| **Prometheus** | Metrics collection (scrapes all pods with `prometheus.io/scrape: "true"`) | Route or port-forward |
| **Grafana** | Dashboards (admin/admin) | Route or port-forward |
| **OpenSearch** | Log storage | Via service |
| **Logstash** | Log shipping (receives from Spring Boot logstash appender on port 5000) | Via service |
| **OpenSearch Dashboards** | Log exploration | Route or port-forward |

### Metrics & Alerting

Each service exposes Prometheus metrics at `/actuator/prometheus`:
- `eureka-server:8761`
- `auth-service:8081`
- `grades-service:8082`
- `notification-service:8083`
- `api-gateway:8080`

The `ServiceMonitor` resource enables automatic scraping. Annotations on pods control scrape configuration:
```yaml
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "8081"
  prometheus.io/path: "/actuator/prometheus"
```

---

## 10. Managing the Cluster

### Start / Stop

```bash
# Start Minishift (if stopped)
minishift start --cpus 4 --memory 8192

# Stop Minishift (preserves VM state)
minishift stop

# Check status
minishift status
```

### Viewing Status

```bash
# All pods in the project
oc get pods -n mytutorial -o wide

# DeploymentConfig status
oc get dc -n mytutorial

# Rollout history
oc rollout history dc/auth-service -n mytutorial

# Logs
oc logs -f dc/auth-service -n mytutorial

# Describe a pod
oc describe pod <pod-name> -n mytutorial
```

### Scaling

```bash
# Manually scale (overrides HPA if HPA is removed)
oc scale dc/auth-service --replicas=3 -n mytutorial

# Check HPA status
oc get hpa -n mytutorial
```

### Updating ConfigMaps

```bash
# Edit a ConfigMap
oc edit configmap auth-service-config -n mytutorial

# After editing, trigger a new rollout
oc rollout latest dc/auth-service -n mytutorial

# Or patch directly
oc patch configmap auth-service-config -n mytutorial -p '{"data":{"SERVER_PORT":"8081"}}'
```

---

## 11. Persistence & Storage

| Component | Type | Storage | PVC Size |
|-----------|------|---------|----------|
| **PostgreSQL** | StatefulSet | `postgres-data` (volumeClaimTemplate) | 5Gi |
| **Kafka** | StatefulSet | `kafka-data` (volumeClaimTemplate) | 5Gi |
| **Redis** | Deployment | EmptyDir (ephemeral) | — |

Postgres and Kafka use **StatefulSets with PersistentVolumeClaims**. Data survives pod restarts but **not Minishift VM deletion** (`minishift delete` destroys everything).

To inspect storage:
```bash
oc get pvc -n mytutorial
oc get pv
```

---

## 12. Rebuilding a Single Service

```bash
# Rebuild and redeploy one service
./scripts/rebuild-service.sh auth-service

# Available services:
# - eureka-server
# - auth-service
# - grades-service
# - notification-service
# - api-gateway
```

This script:
1. Builds the single service image via host Docker
2. Pushes to Minishift's internal registry
3. Updates the ImageStream tag
4. Triggers a new rollout of the DeploymentConfig (which auto-detects the ImageStream change)
5. Waits for the rollout to complete

---

## 13. Resetting the Cluster

```bash
# WARNING: This destroys the entire Minishift VM and ALL data
./scripts/reset-local.sh
```

The reset script:
1. Deletes the Minishift VM (`minishift delete`)
2. Cleans up Docker images tagged for the Minishift registry
3. All PVCs, volumes, and data are permanently deleted

After reset:
```bash
# Start fresh
minishift start --cpus 4 --memory 8192
./scripts/deploy-minishift.sh dev
```

---

## 14. Troubleshooting

### Minishift won't start

```bash
# Check driver availability
minishift start --help | grep driver

# Use a specific driver (KVM recommended on Linux)
minishift start --vm-driver kvm2 --cpus 4 --memory 8192

# Check logs
minishift logs --follow

# Common issues:
# - Virtualization not enabled in BIOS
# - KVM/libvirt not installed (Linux): sudo apt install libvirt-daemon-system libvirt-clients qemu-kvm
# - HyperKit not installed (macOS): brew install hyperkit
```

### Image pull errors

```bash
# Check ImageStream status
oc get imagestream -n mytutorial
oc describe imagestream auth-service -n mytutorial

# Re-push the image
docker login -u $(oc whoami) -p $(oc whoami -t) $(minishift ip):5000 --tls-verify=false
docker tag mytutorial/auth-service:latest $(minishift ip):5000/mytutorial/auth-service:latest
docker push $(minishift ip):5000/mytutorial/auth-service:latest
oc tag --source=docker $(minishift ip):5000/mytutorial/auth-service:latest auth-service:latest -n mytutorial
```

### Pods stuck in CrashLoopBackOff

```bash
# Check logs
oc logs -f <pod-name> -n mytutorial

# Check events
oc get events -n mytutorial --sort-by='.lastTimestamp'

# Check if infrastructure is ready
oc get pods -l tier=infrastructure -n mytutorial

# Check ConfigMap values
oc describe configmap auth-service-config -n mytutorial
```

### Route not accessible

```bash
# Verify route exists
oc get route api-gateway -n mytutorial

# Check the Minishift IP
minishift ip

# Test with explicit IP
curl -k https://api-gateway-mytutorial.$(minishift ip).nip.io/actuator/health

# Ensure the OpenShift router addon is enabled
minishift addons enable default-route
```

### Registry login fails

```bash
# Get the registry URL
minishift openshift registry

# Log in with the token
docker login -u developer -p $(oc whoami -t) $(minishift ip):5000 --tls-verify=false

# If using podman:
podman login -u developer -p $(oc whoami -t) $(minishift ip):5000 --tls-verify=false
```

### DeploymentConfig not rolling out on image change

```bash
# Manually trigger
oc rollout latest dc/auth-service -n mytutorial

# Check rollout history
oc rollout history dc/auth-service -n mytutorial

# Verify ImageStream triggers are set
oc get dc auth-service -n mytutorial -o yaml | grep -A5 triggers
```

### Out of disk space

```bash
# Check Minishift disk usage
minishift ssh -- df -h

# Clean up old images
minishift ssh -- docker image prune -f

# Or use a larger disk
minishift start --disk-size 50g
```
