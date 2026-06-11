# Deploying & Managing Containerized Applications on Google Cloud (GKE)

This guide covers deploying the MyTutorial microservices stack on **Google Kubernetes Engine (GKE)** — from cluster creation and networking to CI/CD, scaling, and day-2 operations — using the existing `k8s/` manifests in this repo.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites & Tooling](#2-prerequisites--tooling)
3. [Container Registry — Artifact Registry](#3-container-registry--artifact-registry)
4. [Provisioning the GKE Cluster](#4-provisioning-the-gke-cluster)
5. [Deploying Infrastructure (Cloud SQL, Memorystore)](#5-deploying-infrastructure-cloud-sql-memorystore)
6. [Deploying the Application](#6-deploying-the-application)
7. [Exposing Services (Ingress)](#7-exposing-services-ingress)
8. [Configuration & Secrets](#8-configuration--secrets)
9. [CI/CD Pipeline](#9-cicd-pipeline)
10. [Auto-Scaling](#10-auto-scaling)
11. [Observability](#11-observability)
12. [Day-2 Operations](#12-day-2-operations)
13. [Cost Optimization](#13-cost-optimization)
14. [Troubleshooting](#14-troubleshooting)

---

## 1. Architecture Overview

```
                              ┌──────────────┐
                              │  Cloud DNS   │
                              │ api.mytutorial.io│
                              └──────┬───────┘
                                     │
                              ┌──────▼───────┐
                              │  HTTPS LB    │  ← GKE Ingress (GLBC)
                              │  (SSL, CDN,  │     provisions HTTP LB
                              │   Cloud Armor)│     automatically
                              └──────┬───────┘
                                     │
                          ┌──────────┼──────────┐
                          │          │          │
                    ┌─────▼────┐ ┌──▼──────┐ ┌─▼────────┐
                    │ api-     │ │ auth-   │ │ grades-   │
                    │ gateway  │ │ service │ │ service   │
                    │ :80      │ │ :8081   │ │ :8082    │
                    │ 2-10 pod │ │ 2-10    │ │ 2-10     │
                    └─────┬────┘ └──┬──────┘ └────┬─────┘
                          │         │              │
                    ┌─────▼────┐   │              │
                    │ eureka-  │   │              │
                    │ server   │   │              │
                    │ :8761    │   │              │
                    │ 1 pod    │   │              │
                    └──────────┘   │              │
                          ┌────────▼──┐    ┌──────▼──────┐
                          │ notifica- │    │  GKE        │
                          │ tion-svc  │    │  (Autopilot │
                          │ :8083     │    │  or Standard)│
                          │ 1-5 pod   │    └─────────────┘
                          └─────┬─────┘
                                │
        ┌───────────────────────┼──────────────────────┐
        │                       │                      │
  ┌─────▼──────┐        ┌──────▼──────┐       ┌───────▼────────┐
  │ Cloud SQL  │        │ Memorystore  │       │ Pub/Sub        │
  │ PostgreSQL │        │ Redis        │       │ (Kafka alt)    │
  │ db-custom   │        │ 1-7 GiB      │       │ or Confluent   │
  │ 1-2-3840   │        │             │       │ on GKE         │
  └────────────┘        └─────────────┘       └────────────────┘
```

### GCP Services Used

| Component | GCP Service | Replacement For |
|-----------|------------|-----------------|
| **Kubernetes** | GKE (Autopilot or Standard) | K8s control plane + nodes |
| **Container Registry** | Artifact Registry | Docker image storage |
| **Ingress** | GKE Ingress (GLBC) + HTTP LB | External HTTP/HTTPS load balancer |
| **DNS** | Cloud DNS | Domain name resolution |
| **SSL** | Google-managed certificates | TLS termination |
| **Database** | Cloud SQL for PostgreSQL | RDS equivalent |
| **Cache** | Memorystore for Redis | ElastiCache equivalent |
| **Messaging** | Pub/Sub or Kafka on GKE | MSK equivalent |
| **Secrets** | Secret Manager | AWS Secrets Manager equivalent |
| **Monitoring** | Cloud Monitoring + Cloud Logging | CloudWatch / AMP equivalent |
| **Tracing** | Cloud Trace | AWS X-Ray equivalent |
| **Profiling** | Cloud Profiler | CPU/heap profiling |
| **Cost** | Cloud Billing + Recommender | Cost analysis |
| **IAM** | Workload Identity Federation | IRSA equivalent |

---

## 2. Prerequisites & Tooling

### Required Tools

```bash
# ── Core ──
gcloud --version                     # Google Cloud CLI (v470+)
kubectl version --client             # Kubernetes CLI (v1.28+)
docker --version                     # Container runtime (v24+)

# ── Recommended ──
kustomize version                    # Manifest overlays
helm version                         # K8s addon packages
gcloud components install gke-gcloud-auth-plugin  # GKE auth plugin

# ── Authenticate ──
gcloud auth login
gcloud config set project mytutorial-project
gcloud auth configure-docker
```

### IAM Permissions Required

| Role | Why |
|------|-----|
| `roles/container.admin` | Create/manage GKE clusters |
| `roles/compute.admin` | VPC, subnets, firewall rules |
| `roles/iam.securityAdmin` | Service accounts, IAM policies |
| `roles/artifactregistry.admin` | Push/pull container images |
| `roles/cloudsql.admin` | Create Cloud SQL instances |
| `roles/redis.admin` | Create Memorystore instances |
| `roles/secretmanager.admin` | Store/retrieve secrets |

### Enable Required GCP APIs

```bash
gcloud services enable \
  container.googleapis.com \
  compute.googleapis.com \
  artifactregistry.googleapis.com \
  cloudsql.googleapis.com \
  redis.googleapis.com \
  secretmanager.googleapis.com \
  cloudresourcemanager.googleapis.com \
  monitoring.googleapis.com \
  logging.googleapis.com \
  cloudtrace.googleapis.com \
  cloudprofiler.googleapis.com
```

---

## 3. Container Registry — Artifact Registry

### 3.1 Create Repository

```bash
# Create a Docker repository in Artifact Registry
gcloud artifacts repositories create mytutorial \
  --repository-format docker \
  --location us-central1 \
  --description "MyTutorial container images"

# Verify
gcloud artifacts repositories list
```

### 3.2 Authenticate & Push

```bash
# Configure Docker to use Artifact Registry
gcloud auth configure-docker us-central1-docker.pkg.dev

# Tag and push all services
PROJECT_ID=$(gcloud config get-value project)
REGISTRY="us-central1-docker.pkg.dev/$PROJECT_ID/mytutorial"
TAG=$(git rev-parse --short HEAD)

for svc in eureka-server auth-service grades-service notification-service api-gateway; do
  docker build \
    -f "backend/$svc/Dockerfile" \
    -t "$REGISTRY/$svc:$TAG" \
    -t "$REGISTRY/$svc:latest" \
    ./backend

  docker push "$REGISTRY/$svc:$TAG"
  docker push "$REGISTRY/$svc:latest"
done
```

### 3.3 Cleanup Policy

```bash
# Keep only the last 10 images per service
gcloud artifacts repositories set-cleanup-policies mytutorial \
  --location us-central1 \
  --policy cleanups.json \
  --no-dry-run

# cleanups.json:
# {
#   "policies": [
#     {
#       "id": "keep-recent-10",
#       "action": "delete",
#       "condition": {
#         "olderThan": "30d",
#         "tagState": "any"
#       },
#       "mostRecentVersions": {
#         "keepCount": 10
#       }
#     }
#   ]
# }
```

---

## 4. Provisioning the GKE Cluster

### 4.1 Option A: GKE Autopilot (Fully Managed)

**Autopilot** is the recommended starting point — Google manages the nodes, you only pay for pods:

```bash
gcloud container clusters create-auto mytutorial \
  --region us-central1 \
  --project "$PROJECT_ID" \
  --network mytutorial-vpc \
  --subnetwork mytutorial-subnet \
  --enable-private-nodes \
  --release-channel regular
```

Autopilot handles:
- Node provisioning and scaling
- Security patching
- Node pool management
- Workload placement optimization

### 4.2 Option B: GKE Standard (More Control)

For teams that need node-level control (GPU, custom images, node taints):

```bash
# Create VPC
gcloud compute networks create mytutorial-vpc --subnet-mode custom
gcloud compute networks subnets create mytutorial-subnet \
  --network mytutorial-vpc \
  --region us-central1 \
  --range 10.0.0.0/16 \
  --secondary-range pods=10.1.0.0/16,services=10.2.0.0/20

# Create cluster
gcloud container clusters create mytutorial \
  --region us-central1 \
  --cluster-version 1.31 \
  --network mytutorial-vpc \
  --subnetwork mytutorial-subnet \
  --enable-ip-alias \
  --enable-private-nodes \
  --master-ipv4-cidr 172.16.0.0/28 \
  --enable-master-authorized-networks \
  --master-authorized-networks 0.0.0.0/0 \
  --num-nodes 3 \
  --machine-type e2-standard-2 \
  --disk-type pd-ssd \
  --disk-size 50 \
  --enable-autoscaling \
  --min-nodes 3 \
  --max-nodes 10 \
  --scopes=cloud-platform \
  --addons HorizontalPodAutoscaling,HttpLoadBalancing,NodeLocalDNS,GcpFilestoreCsiDriver \
  --enable-autorepair \
  --enable-autoupgrade \
  --release-channel regular

# Create node pool for spot instances (stateless workloads)
gcloud container node-pools create spot-pool \
  --cluster mytutorial \
  --region us-central1 \
  --machine-type e2-standard-2 \
  --num-nodes 1 \
  --min-nodes 0 \
  --max-nodes 20 \
  --enable-autoscaling \
  --spot \
  --node-taints=spot=true:NoSchedule
```

### 4.3 Configure kubectl

```bash
gcloud container clusters get-credentials mytutorial --region us-central1
kubectl get nodes  # Verify
```

### 4.4 Install GKE Auth Plugin

```bash
gcloud components install gke-gcloud-auth-plugin
echo "export USE_GKE_GCLOUD_AUTH_PLUGIN=True" >> ~/.bashrc
```

### 4.5 Create Namespace

```bash
kubectl create namespace mytutorial
```

---

## 5. Deploying Infrastructure (Cloud SQL, Memorystore)

### 5.1 Cloud SQL for PostgreSQL

```bash
# Create Cloud SQL instance
gcloud sql instances create mytutorial-postgres \
  --database-version POSTGRES_16 \
  --region us-central1 \
  --cpu 2 \
  --memory 4Gi \
  --storage-size 20 \
  --storage-type SSD \
  --storage-auto-increase \
  --backup-start-time 03:00 \
  --enable-point-in-time-recovery \
  --retained-transaction-log-days 7 \
  --availability-type ZONAL \
  --deletion-protection

# Create database
gcloud sql databases create postgres --instance mytutorial-postgres

# Create user
gcloud sql users create postgres --instance mytutorial-postgres --password=mypassword

# Get private IP
gcloud sql instances describe mytutorial-postgres \
  --format 'value(ipAddresses[0].ipAddress)'
```

### 5.2 Memorystore for Redis

```bash
gcloud redis instances create mytutorial-redis \
  --size 1 \
  --region us-central1 \
  --redis-version redis_7_2 \
  --network mytutorial-vpc \
  --connect-mode PRIVATE_SERVICE_ACCESS \
  --enable-auth \
  --auth-string=mypassword

# Get Redis endpoint
gcloud redis instances describe mytutorial-redis --region us-central1 \
  --format 'value(host)'
```

### 5.3 Pub/Sub (Kafka Alternative)

```bash
# Create topics
gcloud pubsub topics create auth-events

# Create subscriptions
gcloud pubsub subscriptions create auth-events-sub \
  --topic auth-events \
  --ack-deadline 60 \
  --message-retention-duration 7d
```

If you need Kafka specifically, deploy **Confluent for Kubernetes** on GKE instead of Pub/Sub:

```bash
# Deploy Confluent Operator
helm repo add confluentinc https://packages.confluent.io/helm
helm install confluent-operator confluentinc/confluent-for-kubernetes \
  -n confluent --create-namespace

# Deploy Kafka cluster
kubectl apply -f - <<'EOF'
apiVersion: platform.confluent.io/v1beta1
kind: Kafka
metadata:
  name: kafka
spec:
  replicas: 3
  image:
    application: confluentinc/cp-server:7.6.0
    init: confluentinc/confluent-init-container:2.8.0
  dataVolumeCapacity: 50Gi
  configOverrides:
    server:
      - confluent.support.metrics.enable=false
EOF
```

### 5.4 Create Secrets in Secret Manager

```bash
# Store JWT secret
echo -n '3f8a2b1c9d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a' | \
  gcloud secrets create mytutorial-jwt-secret --data-file=-

# Store DB password
echo -n 'mypassword' | \
  gcloud secrets create mytutorial-db-password --data-file=-

# Grant GKE service account access
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format 'value(projectNumber)')
GKE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

gcloud secrets add-iam-policy-binding mytutorial-jwt-secret \
  --member "serviceAccount:$GKE_SA" \
  --role roles/secretmanager.secretAccessor

gcloud secrets add-iam-policy-binding mytutorial-db-password \
  --member "serviceAccount:$GKE_SA" \
  --role roles/secretmanager.secretAccessor
```

---

## 6. Deploying the Application

### 6.1 Grant GKE Nodes Access to GCP Services

```bash
# Get the GKE default service account
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format 'value(projectNumber)')
GKE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

# Grant permissions
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member "serviceAccount:$GKE_SA" \
  --role roles/artifactregistry.reader

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member "serviceAccount:$GKE_SA" \
  --role roles/secretmanager.secretAccessor
```

### 6.2 Update ConfigMaps with GCP Endpoints

Extract the GCP infrastructure endpoints:

```bash
# Cloud SQL
DB_HOST=$(gcloud sql instances describe mytutorial-postgres \
  --format 'value(ipAddresses[0].ipAddress)')

# Memorystore
MEMORYSTORE_HOST=$(gcloud redis instances describe mytutorial-redis \
  --region us-central1 --format 'value(host)')

# Print for reference
echo "DB: $DB_HOST"
echo "Redis: $MEMORYSTORE_HOST"
```

Update the ConfigMaps with these values:

```yaml
# Apply over the base configmaps.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: mytutorial-shared
data:
  SPRING_PROFILES_ACTIVE: "k8s"
  EUREKA_CLIENT_SERVICEURL_DEFAULTZONE: "http://eureka-server:8761/eureka/"
  SPRING_DATASOURCE_URL: "jdbc:postgresql://${DB_HOST}:5432/postgres"
  SPRING_DATASOURCE_USERNAME: "postgres"
  SPRING_DATA_REDIS_HOST: "${MEMORYSTORE_HOST}"
  SPRING_DATA_REDIS_PORT: "6379"
  SPRING_KAFKA_BOOTSTRAP_SERVERS: "kafka:9092"
  LOGGING_LOGSTASH_HOST: "logstash"
  LOGGING_LOGSTASH_PORT: "5000"
```

```bash
# Substitute and apply
sed -e "s|\${DB_HOST}|$DB_HOST|g" \
    -e "s|\${MEMORYSTORE_HOST}|$MEMORYSTORE_HOST|g" \
    k8s/base/configmaps.yaml | kubectl apply -n mytutorial -f -
```

### 6.3 Mount Secrets from Secret Manager

GKE nodes can access Secret Manager via the compute service account. Use **External Secrets Operator** or direct volume mount:

```yaml
# Option 1: External Secrets Operator (recommended)
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: gcp-secretstore
spec:
  provider:
    gcpsm:
      projectID: ${PROJECT_ID}
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: mytutorial-secrets
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: gcp-secretstore
    kind: SecretStore
  target:
    name: mytutorial-secrets
  data:
    - secretKey: SPRING_DATASOURCE_PASSWORD
      remoteRef:
        key: mytutorial-db-password
    - secretKey: APP_JWT_SECRET
      remoteRef:
        key: mytutorial-jwt-secret
```

### 6.4 Update Image References

```bash
# Update the deployment images to Artifact Registry
REGISTRY="us-central1-docker.pkg.dev/$PROJECT_ID/mytutorial"

for svc in eureka-server auth-service grades-service notification-service api-gateway; do
  kubectl set image deployment/$svc \
    "$svc=$REGISTRY/$svc:latest" \
    -n mytutorial
done
```

Or modify the Kustomize overlay:

```yaml
# k8s/overlays/prod/kustomization.yaml
images:
  - name: mytutorial/eureka-server
    newName: us-central1-docker.pkg.dev/myproject/mytutorial/eureka-server
    newTag: abc1234
  - name: mytutorial/auth-service
    newName: us-central1-docker.pkg.dev/myproject/mytutorial/auth-service
    newTag: abc1234
  # ... same for grades-service, notification-service, api-gateway
```

### 6.5 Deploy

```bash
# Deploy everything
kustomize build k8s/overlays/prod | kubectl apply -n mytutorial -f -

# Apply infrastructure (if not using managed services — dev only)
kubectl apply -n mytutorial -f k8s/infrastructure/

# Apply monitoring
kubectl apply -n mytutorial -f k8s/monitoring/

# Verify
kubectl get pods,services,hpa -n mytutorial
```

### 6.6 Workload Identity (Alternative to Node SA)

For finer-grained pod-level permissions, use **Workload Identity**:

```bash
# Create a dedicated GCP service account
gcloud iam service-accounts create mytutorial-sa \
  --display-name "MyTutorial Pod SA"

# Grant Secret Manager access
gcloud secrets add-iam-policy-binding mytutorial-jwt-secret \
  --member "serviceAccount:mytutorial-sa@$PROJECT_ID.iam.gserviceaccount.com" \
  --role roles/secretmanager.secretAccessor

# Grant Artifact Registry access
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member "serviceAccount:mytutorial-sa@$PROJECT_ID.iam.gserviceaccount.com" \
  --role roles/artifactregistry.reader

# Create K8s service account and bind
kubectl create serviceaccount mytutorial-sa -n mytutorial

gcloud iam service-accounts add-iam-policy-binding \
  mytutorial-sa@$PROJECT_ID.iam.gserviceaccount.com \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:$PROJECT_ID.svc.id.goog[mytutorial/mytutorial-sa]"

kubectl annotate serviceaccount mytutorial-sa \
  iam.gke.io/gcp-service-account=mytutorial-sa@$PROJECT_ID.iam.gserviceaccount.com \
  -n mytutorial
```

Then reference the KSA in each Deployment:

```yaml
spec:
  template:
    spec:
      serviceAccountName: mytutorial-sa
```

---

## 7. Exposing Services (Ingress)

### 7.1 GKE Ingress (HTTP Load Balancer)

GKE Ingress provisions a Google Cloud HTTP(S) Load Balancer automatically:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: api-gateway
  namespace: mytutorial
  annotations:
    # GKE-specific annotations
    kubernetes.io/ingress.class: "gce"
    kubernetes.io/ingress.global-static-ip-name: "mytutorial-ingress-ip"
    networking.gke.io/managed-certificates: "mytutorial-cert"
    networking.gke.io/v1beta1/FrontendConfig: "mytutorial-frontend"
spec:
  defaultBackend:
    service:
      name: api-gateway
      port:
        number: 80
  rules:
    - host: api.mytutorial.io
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

```bash
# Reserve a static IP
gcloud compute addresses create mytutorial-ingress-ip \
  --global \
  --network-tier PREMIUM

# Create managed SSL certificate
kubectl apply -f - <<'EOF'
apiVersion: networking.gke.io/v1
kind: ManagedCertificate
metadata:
  name: mytutorial-cert
  namespace: mytutorial
spec:
  domains:
    - api.mytutorial.io
EOF

# Create FrontendConfig (HTTP → HTTPS redirect)
kubectl apply -f - <<'EOF'
apiVersion: networking.gke.io/v1beta1
kind: FrontendConfig
metadata:
  name: mytutorial-frontend
  namespace: mytutorial
spec:
  redirectToHttps:
    enabled: true
    responseCodeName: MOVED_PERMANENTLY_DEFAULT
EOF

# Apply the Ingress
kubectl apply -f ingress.yaml

# Wait for load balancer to provision (2-5 minutes)
kubectl get ingress api-gateway -n mytutorial -w

# Get the LB IP and configure Cloud DNS
LB_IP=$(gcloud compute addresses describe mytutorial-ingress-ip --global --format 'value(address)')
echo "Point api.mytutorial.io → $LB_IP"
```

### 7.2 Cloud DNS Setup

```bash
# Create DNS zone (one-time)
gcloud dns managed-zones create mytutorial \
  --dns-name=mytutorial.io \
  --description="MyTutorial DNS zone"

# Add A record pointing to the LB
gcloud dns record-sets create api.mytutorial.io \
  --zone=mytutorial \
  --type=A \
  --ttl=300 \
  --rrdatas="$LB_IP"
```

### 7.3 Cloud Armor (WAF)

```bash
# Create security policy
gcloud compute security-policies create mytutorial-waf \
  --description "WAF for MyTutorial"

# Add rules
gcloud compute security-policies rules create 1000 \
  --security-policy mytutorial-waf \
  --description "Rate limit: 1000 req/s per client" \
  --src-ip-ranges "*" \
  --action "throttle" \
  --rate-limit-threshold-count 1000 \
  --rate-limit-threshold-interval-sec 60 \
  --conform-action "allow" \
  --enforce-on-key "IP"

# Block SQL injection and XSS
gcloud compute security-policies rules create 2000 \
  --security-policy mytutorial-waf \
  --description "Block SQL injection" \
  --src-ip-ranges "*" \
  --action "deny(403)" \
  --preconfigured-waf-rules '{"sqli": {"sensitivity": 2}}'

# Attach to the backend service
gcloud compute backend-services update --global \
  --security-policy mytutorial-waf \
  k8s-backend-xxxxx
```

### 7.4 Alternative: NGINX Ingress on GKE

For more control (rewrites, headers, authentication), use NGINX Ingress instead:

```bash
# Deploy NGINX Ingress Controller
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm install nginx-ingress ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace

# Now use standard NGINX ingress annotations (same as any K8s cluster)
```

---

## 8. Configuration & Secrets

### 8.1 Secret Manager CSI Driver

Mount secrets from Secret Manager directly as files:

```bash
# Install the CSI driver
gcloud container clusters update mytutorial \
  --region us-central1 \
  --update-addons GcpFilestoreCsiDriver=ENABLED

# Then mount secrets in the Deployment:
```

```yaml
volumes:
  - name: secrets
    csi:
      driver: secrets-store.csi.k8s.io
      readOnly: true
      volumeAttributes:
        secretProviderClass: mytutorial-secrets
---
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: mytutorial-secrets
spec:
  provider: gcp
  parameters:
    secrets: |
      - resourceName: projects/$PROJECT_ID/secrets/mytutorial-jwt-secret/versions/latest
        path: jwt-secret
      - resourceName: projects/$PROJECT_ID/secrets/mytutorial-db-password/versions/latest
        path: db-password
```

### 8.2 External Secrets Operator

```bash
# Install ESO
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace
```

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: gcp-secretstore
spec:
  provider:
    gcpsm:
      projectID: mytutorial-project
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: mytutorial-secrets
  namespace: mytutorial
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: gcp-secretstore
    kind: ClusterSecretStore
  target:
    name: mytutorial-secrets
    deletionPolicy: Delete
  data:
    - secretKey: SPRING_DATASOURCE_PASSWORD
      remoteRef:
        key: mytutorial-db-password
    - secretKey: APP_JWT_SECRET
      remoteRef:
        key: mytutorial-jwt-secret
```

### 8.3 Spring Profile for GCP

The existing `application-k8s.yml` profile works on GKE — it uses K8s service DNS names (`redis`, `kafka`, `postgres`, `eureka-server`). For managed services (Cloud SQL, Memorystore), override via ConfigMap env vars:

```yaml
# The k8s profile reads these from environment variables (set in ConfigMap)
# SPRING_DATASOURCE_URL - set to Cloud SQL endpoint
# SPRING_DATA_REDIS_HOST - set to Memorystore endpoint
```

---

## 9. CI/CD Pipeline

### 9.1 Cloud Build (Google-Native CI/CD)

```yaml
# cloudbuild.yaml
steps:
  # Step 1: Run tests
  - name: maven:3.9-eclipse-temurin-21
    entrypoint: mvn
    args: ['-B', 'test', '-q']
    dir: backend

  # Step 2: Build and push images
  - name: gcr.io/cloud-builders/docker
    entrypoint: bash
    args:
      - -c
      - |
        for svc in eureka-server auth-service grades-service notification-service api-gateway; do
          docker build -f "backend/$svc/Dockerfile" \
            -t "us-central1-docker.pkg.dev/$PROJECT_ID/mytutorial/$svc:$SHORT_SHA" \
            -t "us-central1-docker.pkg.dev/$PROJECT_ID/mytutorial/$svc:latest" \
            ./backend
        done

  # Step 3: Push images
  - name: gcr.io/cloud-builders/docker
    entrypoint: bash
    args:
      - -c
      - |
        for svc in eureka-server auth-service grades-service notification-service api-gateway; do
          docker push "us-central1-docker.pkg.dev/$PROJECT_ID/mytutorial/$svc:$SHORT_SHA"
          docker push "us-central1-docker.pkg.dev/$PROJECT_ID/mytutorial/$svc:latest"
        done

  # Step 4: Deploy to GKE
  - name: gcr.io/cloud-builders/kubectl
    entrypoint: bash
    args:
      - -c
      - |
        # Update images with new tag
        for svc in eureka-server auth-service grades-service notification-service api-gateway; do
          kubectl set image deployment/$svc \
            "$svc=us-central1-docker.pkg.dev/$PROJECT_ID/mytutorial/$svc:$SHORT_SHA" \
            -n mytutorial
        done

  # Step 5: Wait for rollout
  - name: gcr.io/cloud-builders/kubectl
    entrypoint: bash
    args:
      - -c
      - |
        for svc in eureka-server auth-service grades-service notification-service api-gateway; do
          kubectl rollout status deployment/$svc -n mytutorial --timeout=300s
        done

substitutions:
  _ENV: prod

options:
  logging: CLOUD_LOGGING_ONLY

images:
  - 'us-central1-docker.pkg.dev/$PROJECT_ID/mytutorial/eureka-server'
  - 'us-central1-docker.pkg.dev/$PROJECT_ID/mytutorial/auth-service'
  - 'us-central1-docker.pkg.dev/$PROJECT_ID/mytutorial/grades-service'
  - 'us-central1-docker.pkg.dev/$PROJECT_ID/mytutorial/notification-service'
  - 'us-central1-docker.pkg.dev/$PROJECT_ID/mytutorial/api-gateway'
```

```bash
# Trigger build
gcloud builds submit --config=cloudbuild.yaml --substitutions=_ENV=prod
```

### 9.2 GitHub Actions + Workload Identity Federation

```yaml
# .github/workflows/deploy-gke.yml
name: Deploy to GKE

on:
  push:
    branches: [main]
    paths:
      - 'backend/**'

env:
  PROJECT_ID: mytutorial-project
  GKE_CLUSTER: mytutorial
  GKE_REGION: us-central1
  REGISTRY: us-central1-docker.pkg.dev/mytutorial-project/mytutorial

permissions:
  id-token: write
  contents: read

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

      - name: Authenticate to GCP
        uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: projects/123456789/locations/global/workloadIdentityPools/my-pool/providers/github
          service_account: gha-deployer@mytutorial-project.iam.gserviceaccount.com

      - name: Configure Docker
        run: gcloud auth configure-docker us-central1-docker.pkg.dev

      - name: Build and push images
        env:
          TAG: ${{ github.sha }}
        run: |
          for svc in eureka-server auth-service grades-service notification-service api-gateway; do
            docker build -f "backend/$svc/Dockerfile" \
              -t "$REGISTRY/$svc:$TAG" \
              -t "$REGISTRY/$svc:latest" \
              ./backend
            docker push "$REGISTRY/$svc:$TAG"
            docker push "$REGISTRY/$svc:latest"
          done

      - name: Get GKE credentials
        uses: google-github-actions/get-gke-credentials@v2
        with:
          cluster_name: ${{ env.GKE_CLUSTER }}
          location: ${{ env.GKE_REGION }}

      - name: Deploy
        run: |
          for svc in eureka-server auth-service grades-service notification-service api-gateway; do
            kubectl set image deployment/$svc \
              "$svc=$REGISTRY/$svc:${{ github.sha }}" \
              -n mytutorial
          done

      - name: Verify rollout
        run: |
          for svc in eureka-server auth-service grades-service notification-service api-gateway; do
            kubectl rollout status deployment/$svc -n mytutorial --timeout=300s
          done
```

### 9.3 Workload Identity Federation Setup

```bash
# Create a workload identity pool
gcloud iam workload-identity-pools create github-pool \
  --location global \
  --display-name "GitHub Actions Pool"

# Create OIDC provider for GitHub
gcloud iam workload-identity-pools providers create-oidc github-provider \
  --location global \
  --workload-identity-pool github-pool \
  --issuer-uri https://token.actions.githubusercontent.com \
  --attribute-mapping "google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository" \
  --attribute-condition "attribute.repository == 'your-org/mytutorial'"

# Get pool name
POOL_NAME=$(gcloud iam workload-identity-pools describe github-pool \
  --location global --format 'value(name)')

# Create service account for GitHub
gcloud iam service-accounts create gha-deployer \
  --display-name "GitHub Actions Deployer"

# Grant deploy permissions
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member "serviceAccount:gha-deployer@$PROJECT_ID.iam.gserviceaccount.com" \
  --role roles/container.developer

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member "serviceAccount:gha-deployer@$PROJECT_ID.iam.gserviceaccount.com" \
  --role roles/artifactregistry.writer

# Allow GitHub to impersonate
gcloud iam service-accounts add-iam-policy-binding \
  gha-deployer@$PROJECT_ID.iam.gserviceaccount.com \
  --role roles/iam.workloadIdentityUser \
  --member "principalSet://iam.googleapis.com/$POOL_NAME/attribute.repository/your-org/mytutorial"
```

---

## 10. Auto-Scaling

### 10.1 Horizontal Pod Autoscaler (HPA)

The existing `k8s/base/hpas.yaml` works on GKE without changes:

```bash
# Verify HPA
kubectl get hpa -n mytutorial
kubectl describe hpa auth-service-hpa -n mytutorial

# Expected behavior:
# - Scales auth, grades, gateway between 2-10 pods
# - Scales notification between 1-5 pods
# - Triggers at 70% CPU or 80% memory
```

### 10.2 Cluster Autoscaler (Standard Mode)

GKE Standard includes cluster autoscaler by default (enabled at cluster creation):

```bash
# It automatically adds/removes nodes based on pending pods
# No additional configuration needed if --enable-autoscaling was set
```

### 10.3 GKE Autopilot

In Autopilot mode, node autoscaling is completely managed:

```bash
# You don't manage nodes — just set Pod resource requests/limits
# Google handles node provisioning automatically
```

### 10.4 Vertical Pod Autoscaler (GKE)

GKE has a managed VPA that can be enabled:

```bash
# Enable VPA addon on existing cluster
gcloud container clusters update mytutorial \
  --region us-central1 \
  --enable-vertical-pod-autoscaling
```

```yaml
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
    updateMode: "Off"  # Recommend only; use "Auto" to automatically update
  resourcePolicy:
    containerPolicies:
      - containerName: '*'
        minAllowed:
          cpu: 100m
          memory: 256Mi
        maxAllowed:
          cpu: 2
          memory: 2Gi
```

```bash
# View VPA recommendations
kubectl describe vpa auth-service-vpa -n mytutorial
# Output shows:
#   Container Recommendations:
#     Target:
#       cpu: 350m
#       memory: 768Mi
```

### 10.5 Pod Disruption Budgets

Already in `k8s/base/pdbs.yaml`:

```bash
kubectl get pdb -n mytutorial

# Ensures at least 1 pod stays up during:
# - Node maintenance
# - Rolling updates
# - Cluster upgrades (GKE automatically drains nodes)
```

### 10.6 Prevent Pending Pods with PodDisruptionBudget

GKE uses **PodDisruptionBudget** during node pool upgrades to maintain availability:

```bash
# GKE respects PDBs during node upgrades
# It will:
# 1. Create a new node
# 2. Evict pods with PDB that allow it
# 3. Wait for PDB if minAvailable would be violated
```

---

## 11. Observability

### 11.1 Cloud Logging & Cloud Monitoring

GKE integrates with Cloud Logging and Cloud Monitoring automatically:

```bash
# Metrics collected automatically:
# - Container CPU, memory, disk, network
# - Node-level metrics
# - API server metrics

# Logs collected automatically from stdout/stderr of all containers
```

Access via:
- **Logs Explorer**: `https://console.cloud.google.com/logs`
- **Metrics Explorer**: `https://console.cloud.google.com/monitoring`
- **Kubernetes Engine → Workloads → select workload → Observability tab**

### 11.2 Custom Dashboards

Create a dashboard for JVM metrics using Cloud Monitoring:

```bash
# Use the Monitoring API or UI
# gcloud monitoring dashboards create --config-from-file=dashboard.json
```

Example dashboard panels to create:

| Panel | Metric | Filter |
|-------|--------|--------|
| **CPU usage** | `kubernetes.io/container/cpu/core_usage_time` | `container_name="auth-service"` |
| **Memory usage** | `kubernetes.io/container/memory/used_bytes` | `container_name="auth-service"` |
| **Request latency** | `logging.googleapis.com/log_entry_count` | Custom log-based metric |
| **Error rate** | 5xx count from Logging | Log-based metric |

### 11.3 Log-Based Metrics

```bash
# Create a log-based metric for HTTP 5xx errors
gcloud logging metrics create http-5xx-count \
  --description "Count of 5xx HTTP responses" \
  --log-filter 'resource.type="k8s_container" AND resource.labels.container_name:"auth-service" AND textPayload:"5.."'
```

### 11.4 Cloud Trace

```bash
# Enable Cloud Trace in GKE
gcloud container clusters update mytutorial \
  --region us-central1 \
  --logging=SYSTEM,WORKLOAD \
  --monitoring=SYSTEM,WORKLOAD
```

Add the Spring Cloud GCP Trace starter to `pom.xml`:

```xml
<dependency>
    <groupId>com.google.cloud</groupId>
    <artifactId>spring-cloud-gcp-starter-trace</artifactId>
</dependency>
```

Then in `application-k8s.yml`:

```yaml
spring:
  cloud:
    gcp:
      trace:
        enabled: true
        sampling-rate: 0.1  # Sample 10% of requests
```

### 11.5 Cloud Profiler

```bash
# Add the Cloud Profiler agent to each service
# The GKE metadata server provides credentials automatically
```

```xml
<dependency>
    <groupId>com.google.cloud</groupId>
    <artifactId>cloud-profiler-java</artifactId>
    <version>3.1.0</version>
</dependency>
```

```java
@PostConstruct
public void startProfiler() {
    CloudProfiler.start(CloudProfilerConfig.builder()
        .service("auth-service")
        .projectId("mytutorial-project")
        .build());
}
```

### 11.6 Alerts

```bash
# Create alert when error rate exceeds threshold
gcloud alpha monitoring policies create \
  --display-name="High 5xx Rate" \
  --condition-display-name="5xx rate > 1% for 5 minutes" \
  --condition-filter='metric.type="logging.googleapis.com/user/http-5xx-count" AND resource.type="k8s_container"' \
  --condition-threshold-value=0.01 \
  --condition-threshold-duration=300s \
  --notification-channels="projects/$PROJECT_ID/notificationChannels/xxxxx"
```

### 11.7 The Existing ELK Stack

The in-cluster ELK stack (Logstash + OpenSearch from `k8s/monitoring/`) also works on GKE:

```
Spring Boot → LogstashTCPAppender(:5000) → Logstash → OpenSearch(:9200) → OpenSearch Dashboards(:5601)
```

This runs alongside GCP-native logging — use Cloud Logging for operations and OpenSearch Dashboards for business/debug logging.

---

## 12. Day-2 Operations

### 12.1 Rolling Updates

```bash
# Standard rolling update (zero-downtime)
kubectl set image deployment/auth-service \
  auth-service=us-central1-docker.pkg.dev/$PROJECT_ID/mytutorial/auth-service:v2.1 \
  -n mytutorial

# Monitor
kubectl rollout status deployment/auth-service -n mytutorial -w

# Rollback
kubectl rollout undo deployment/auth-service -n mytutorial
```

### 12.2 Blue/Green Deployments

```yaml
# Deploy new version alongside current
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: auth-service-green
  labels:
    app: auth-service
    version: green
spec:
  replicas: 2
  selector:
    matchLabels:
      app: auth-service
      version: green
  template:
    metadata:
      labels:
        app: auth-service
        version: green
    spec:
      containers:
        - name: auth-service
          image: us-central1-docker.pkg.dev/$PROJECT_ID/mytutorial/auth-service:new-version
          envFrom: [...]
EOF

# Test the green deployment
kubectl port-forward deployment/auth-service-green 18081:8081 -n mytutorial

# Switch traffic
kubectl patch service auth-service -p '{"spec":{"selector":{"version":"green"}}}' -n mytutorial

# Tear down blue
kubectl delete deployment auth-service -n mytutorial
```

### 12.3 Canary Deployments with GKE

```bash
# Use a service mesh (Anthos Service Mesh) or
# deploy a second, smaller instance and use Cloud Load Balancing for traffic splitting
```

### 12.4 GKE Cluster Upgrades

```bash
# Check current version
gcloud container clusters describe mytutorial \
  --region us-central1 \
  --format 'value(currentMasterVersion)'

# Available versions
gcloud container get-server-config --region us-central1

# Upgrade control plane
gcloud container clusters upgrade mytutorial \
  --master \
  --region us-central1

# Upgrade node pools
gcloud container clusters upgrade mytutorial \
  --node-pool default-pool \
  --region us-central1

# Use surge upgrade for faster node pool upgrades
gcloud container node-pools update default-pool \
  --cluster mytutorial \
  --region us-central1 \
  --max-surge-upgrade 1 \
  --max-unavailable-upgrade 0
```

### 12.5 Backup & Restore

```bash
# Backup Kubernetes resources
kubectl get all -n mytutorial -o yaml > mytutorial-backup-$(date +%Y%m%d).yaml

# Backup Cloud SQL
gcloud sql backups create --instance mytutorial-postgres

# Schedule automated backups (7-day retention by default)
gcloud sql instances patch mytutorial-postgres \
  --backup-start-time 03:00 \
  --retained-backups-count 30

# Restore Cloud SQL
gcloud sql backups restore mytutorial-postgres \
  --backup-id 20240610-030000
```

### 12.6 Node Pool Rotation

```bash
# Create a new node pool with updated image
gcloud container node-pools create rotated-pool \
  --cluster mytutorial \
  --region us-central1 \
  --machine-type e2-standard-2 \
  --num-nodes 3 \
  --node-version 1.31.2-gke.1000

# Cordon and drain old nodes
kubectl cordain -l cloud.google.com/gke-nodepool=default-pool
kubectl drain -l cloud.google.com/gke-nodepool=default-pool --ignore-daemonsets

# Delete old pool
gcloud container node-pools delete default-pool \
  --cluster mytutorial --region us-central1

# Rename new pool
gcloud container node-pools update rotated-pool \
  --cluster mytutorial \
  --region us-central1 \
  --node-labels=...  # Rename via label change
```

### 12.7 Resource Cleanup

```bash
# Get unused resources
kubectl get pvc -n mytutorial | grep Lost
kubectl get configmaps -n mytutorial --no-headers | wc -l

# Remove completed jobs
kubectl delete job --field-selector status.successful=1 -n mytutorial
```

---

## 13. Cost Optimization

### 13.1 GKE-Specific Cost Savings

| Strategy | Implementation | Savings |
|----------|---------------|---------|
| **Autopilot** | Use Autopilot for bursting workloads | 15-30% vs Standard |
| **Spot (preemptible)** | Use spot node pool | 60-90% vs regular |
| **GKE usage metering** | Track per-namespace spend | Visibility |
| **Committed use discounts** | 1-year or 3-year commitment | 20-50% |
| **Sustained use discounts** | Automatic for running >25% of month | Up to 30% |
| **Custom machine types** | Right-size with `e2-custom` | 10-30% |

### 13.2 GKE Autopilot Cost

| Resource | Autopilot Price (us-central1) | Notes |
|----------|-------------------------------|-------|
| CPU | $0.0319/vCPU-hour | Only pay for requested CPU |
| Memory | $0.00428/GiB-hour | Only pay for requested memory |
| Ephemeral storage | $0.00054/GiB-hour | Only pay for requested disk |
| **No node cost** | — | Nodes managed by Google |

### 13.3 Spot Instances

```bash
# Add taint so only spot-tolerant pods run here
gcloud container node-pools create spot-pool \
  --cluster mytutorial \
  --region us-central1 \
  --spot \
  --node-taints=spot=true:NoSchedule
```

Add toleration to Deployments for stateless services:

```yaml
# In spec.template.spec:
tolerations:
  - key: "spot"
    operator: "Equal"
    value: "true"
    effect: "NoSchedule"
```

### 13.4 Right-Sizing

Use GKE VPA recommendations to right-size:

```bash
kubectl describe vpa auth-service-vpa -n mytutorial | grep -A6 "Container Recommendations"
```

Example tuning after VPA data:

| Service | Initial | After VPA | Monthly Savings (3 pods) |
|---------|---------|-----------|----------------------|
| auth-service | 512Mi/1Gi | 350Mi/700Mi | ~$15/mo |
| grades-service | 512Mi/1Gi | 400Mi/800Mi | ~$12/mo |
| api-gateway | 512Mi/1Gi | 300Mi/600Mi | ~$18/mo |

### 13.5 Cloud SQL Cost

```bash
# Use db-custom (custom machine type) for right-sized DB
gcloud sql instances patch mytutorial-postgres \
  --cpu 1 --memory 3.75Gi

# Or use shared-core for dev
gcloud sql instances create mytutorial-postgres-dev \
  --database-version POSTGRES_16 \
  --region us-central1 \
  --tier db-f1-micro
```

### 13.6 Cloud Storage

```bash
# Use nearline for backups older than 30 days
# Cloud SQL automatically manages this with PITR
```

### 13.7 Label Everything for Cost Tracking

```bash
# Add labels to all GKE resources
gcloud container clusters update mytutorial \
  --region us-central1 \
  --update-labels=environment=prod,team=platform,cost-center=engineering

# Enable GKE usage metering
gcloud container clusters update mytutorial \
  --region us-central1 \
  --resource-usage-bigquery-dataset=usage_metering
```

---

## 14. Troubleshooting

### 14.1 GKE-Specific Issues

```bash
# Pod stuck in ContainerCreating
kubectl describe pod auth-service-xxxxx -n mytutorial

# Possible causes:
# - Insufficient GKE node capacity (check node pool autoscaling)
# - Disk quota exceeded (increase PD quota)
# - IP address exhaustion (check secondary range)
# - Firewall rules blocking health checks

# Check node conditions
kubectl get nodes -o yaml | grep -A5 conditions

# Check GKE-specific events
gcloud container operations list --region us-central1 --filter="target=mytutorial"
```

### 14.2 Common GKE Errors

| Error | Cause | Fix |
|-------|-------|-----|
| `RESOURCE_EXHAUSTED` | Quota exceeded | Request quota increase in GCP Console |
| `INSUFFICIENT_IP_SPACE` | Pod CIDR exhausted | Increase secondary range |
| `UNSATISFIABLE` | No node capacity (Autopilot) | Reduce pod resource requests |
| `PodEviction` | Node preempted (spot) | Use podDisruptionBudget + anti-affinity |
| `IMAGE_BACKOFF` | Registry access | Verify Artifact Registry permissions |

### 14.3 Cloud SQL Connectivity

```bash
# Test from a jump pod
kubectl run pgtest --image=postgres:16-alpine --rm -it -n mytutorial -- \
  psql -h PRIVATE_IP -U postgres -d postgres -c "SELECT 1"

# If connection fails:
# 1. Ensure Cloud SQL has private IP
# 2. Ensure GKE and Cloud SQL are in same VPC
# 3. Check firewall: allow 5432 from GKE nodes

# Using Cloud SQL Auth Proxy (alternative)
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudsql-proxy
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cloudsql-proxy
  template:
    metadata:
      labels:
        app: cloudsql-proxy
    spec:
      containers:
        - name: cloudsql-proxy
          image: gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.11
          args:
            - --private-ip
            - mytutorial-postgres:us-central1:postgres
          securityContext:
            runAsNonRoot: true
EOF
```

### 14.4 Memorystore (Redis) Connectivity

```bash
kubectl run redistest --image=redis:7-alpine --rm -it -n mytutorial -- \
  redis-cli -h REDIS_HOST -a "$(gcloud redis instances describe mytutorial-redis --region us-central1 --format 'value(authString)')" ping

# Note: Memorystore requires Private Service Access (VPC peering)
# Ensure the peering is set up correctly
```

### 14.5 IAM / Workload Identity Issues

```bash
# Check if pod has the right service account
kubectl get pod auth-service-xxxxx -n mytutorial -o jsonpath='{.spec.serviceAccount}'

# Check Workload Identity binding
gcloud iam service-accounts get-iam-policy mytutorial-sa@$PROJECT_ID.iam.gserviceaccount.com

# Test from inside the pod
kubectl exec auth-service-xxxxx -n mytutorial -- \
  curl -sf -H "Metadata-Flavor: Google" \
  http://169.254.169.254/computeMetadata/v1/instance/service-accounts/default/identity?audience=https://www.googleapis.com/oauth2/v4/token
```

### 14.6 Debug Pod

```bash
kubectl run debug --image=nicolaka/netshoot --rm -it -n mytutorial -- /bin/bash

# Inside the debug pod:
nslookup auth-service             # DNS resolution
curl -sv http://auth-service:8081  # Service connectivity
curl -sv http://cloudsql-ip:5432   # External DB connectivity
```

### 14.7 Quick Reference

```bash
# ── GKE ──
gcloud container clusters list
gcloud container clusters get-credentials mytutorial --region us-central1
gcloud container operations list --region us-central1

# ── Pods ──
kubectl get pods -n mytutorial -o wide
kubectl logs -n mytutorial -l app=auth-service --tail=50 -f
kubectl exec -it -n mytutorial deployment/auth-service -- /bin/sh
kubectl top pods -n mytutorial

# ── Config ──
kubectl get configmaps,secrets -n mytutorial
kubectl describe configmap auth-service-config -n mytutorial

# ── Networking ──
kubectl get services,ingress -n mytutorial
kubectl get endpoints -n mytutorial

# ── Scaling ──
kubectl get hpa -n mytutorial
kubectl get vpa -n mytutorial

# ── GCP ──
gcloud sql instances list
gcloud redis instances list --region us-central1
gcloud artifacts docker images list us-central1-docker.pkg.dev/$PROJECT_ID/mytutorial
```

---

## Appendix: GCP vs AWS Mapping

| Concept | AWS (EKS) | GCP (GKE) |
|---------|-----------|-----------|
| Container registry | ECR | Artifact Registry |
| Postgres | RDS | Cloud SQL |
| Redis | ElastiCache | Memorystore |
| Messaging | MSK / SQS | Pub/Sub or Kafka on GKE |
| Secrets | Secrets Manager | Secret Manager |
| Load balancer | ALB (via AWS LB Controller) | HTTP LB (via GKE Ingress) |
| SSL cert | ACM | Google-managed certificates |
| DNS | Route 53 | Cloud DNS |
| Logs | CloudWatch Logs | Cloud Logging |
| Metrics | CloudWatch / AMP | Cloud Monitoring |
| Traces | X-Ray | Cloud Trace |
| Profiler | CodeGuru Profiler | Cloud Profiler |
| IAM for pods | IRSA | Workload Identity |
| Node pricing | On-demand, Spot | Regular, Spot (Preemptible) |
| Managed K8s | EKS | GKE Autopilot |
| K8s with nodes | EKS managed node groups | GKE Standard |
| WAF | WAF / Shield | Cloud Armor |
| CDN | CloudFront | Cloud CDN |
| Cost reporting | Cost Explorer | Cloud Billing |

### Migration Checklist

- [ ] Create GKE cluster (Autopilot or Standard)
- [ ] Create Artifact Registry repositories
- [ ] Build and push images
- [ ] Create Cloud SQL, Memorystore, Pub/Sub
- [ ] Store secrets in Secret Manager
- [ ] Set up Workload Identity
- [ ] Update ConfigMaps with GCP endpoints
- [ ] Deploy application via `kustomize`
- [ ] Configure Ingress with managed certificate
- [ ] Set up Cloud DNS
- [ ] Enable Cloud Monitoring, Logging, Trace, Profiler
- [ ] Configure Cloud Armor WAF
- [ ] Set up Cloud Build or GitHub Actions CI/CD

---

## References

- [GKE Documentation](https://cloud.google.com/kubernetes-engine/docs)
- [GKE Best Practices](https://cloud.google.com/kubernetes-engine/docs/best-practices)
- [GKE Autopilot Overview](https://cloud.google.com/kubernetes-engine/docs/concepts/autopilot-overview)
- [Workload Identity](https://cloud.google.com/kubernetes-engine/docs/concepts/workload-identity)
- [Cloud SQL for PostgreSQL](https://cloud.google.com/sql/docs/postgres)
- [Memorystore for Redis](https://cloud.google.com/memorystore/docs/redis)
- [Cloud Build](https://cloud.google.com/build/docs)
- [Secret Manager](https://cloud.google.com/secret-manager/docs)
- [External Secrets Operator (GCP)](https://external-secrets.io/latest/provider/google-secrets-manager/)
- [Spring Cloud GCP](https://spring.io/projects/spring-cloud-gcp)