# MyTutorial — Azure Kubernetes Service (AKS) Deployment

Deploy MyTutorial to Microsoft Azure using AKS with native Azure integrations (Load Balancer, Application Gateway Ingress, managed disks, ACR).

## Architecture

All 5 backend services run as scalable Kubernetes Deployments with:

- **Azure Load Balancer** — `api-gateway` service type `LoadBalancer` provisions an Azure LB automatically
- **Application Gateway Ingress** — optional AGIC for TLS termination, WAF, cookie-based affinity
- **HorizontalPodAutoscaler** — auto-scale based on CPU/memory utilization
- **RollingUpdate strategy** — zero-downtime deployments (maxUnavailable=0)
- **PodDisruptionBudget** — at least 1 pod stays up during voluntary disruptions
- **NetworkPolicies** — restrict ingress traffic, allow Azure LB health probes
- **Azure Premium SSD** — managed disk storage for Postgres

## Prerequisites

| Tool | Required | Notes |
|------|----------|-------|
| `az` CLI | Yes | Authenticated: `az login` |
| `kubectl` | Yes | Configured for your AKS cluster |
| `docker` | Yes | For building images |
| Azure subscription | Yes | With contributor access to a resource group |

```bash
# Install Azure CLI (if needed)
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Login
az login

# Set your subscription
az account set --subscription "your-subscription-id"
```

## Quick Start

### 1. Create AKS Cluster (one-time)

```bash
# Variables
RG=mytutorial-rg
AKS=mytutorial-aks
ACR=mytutorialacr    # must be globally unique

# Create resource group
az group create --name $RG --location eastus

# Create ACR
az acr create --resource-group $RG --name $ACR --sku Basic

# Create AKS with ACR attached
az aks create \
  --resource-group $RG \
  --name $AKS \
  --node-count 3 \
  --enable-cluster-autoscaler \
  --min-count 2 \
  --max-count 6 \
  --node-vm-size Standard_DS2_v2 \
  --attach-acr $ACR \
  --generate-ssh-keys

# Get credentials
az aks get-credentials --resource-group $RG --name $AKS
```

### 2. Build and Push Images

```bash
# Build all 5 services and push to ACR
REGISTRY=${ACR}.azurecr.io ./deploy-azure/scripts/build-and-push.sh
```

### 3. Deploy

```bash
# Deploy to dev environment (1 replica each)
./deploy-azure/scripts/deploy.sh dev

# Deploy to staging (2 replicas)
./deploy-azure/scripts/deploy.sh staging

# Deploy to prod (3 replicas)
./deploy-azure/scripts/deploy.sh prod
```

### 4. Access

The deploy script waits for the Load Balancer IP and prints it:

```bash
# Manually get the IP
kubectl get svc api-gateway -n mytutorial

# Test
curl http://<LB-IP>/api/signin
```

## Directory Structure

```
deploy-azure/
├── base/                        # Base manifests (shared across environments)
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── storage-class.yaml       # Azure Premium SSD + Standard SSD StorageClasses
│   ├── configmaps.yaml
│   ├── deployments.yaml
│   ├── services.yaml
│   ├── ingress.yaml             # AGIC (Application Gateway Ingress)
│   ├── hpas.yaml
│   ├── pdbs.yaml
│   └── network-policies.yaml    # Includes Azure LB health-probe rule
├── overlays/
│   ├── dev/                     # Dev: 1 replica, HPA 1-3
│   ├── staging/                 # Staging: 2 replicas, standard resources
│   └── prod/                    # Prod: 3 replicas, HPA 3-15
├── infrastructure/              # Postgres (Premium SSD), Redis, Kafka
├── monitoring/                  # Prometheus (pod auto-discovery)
└── scripts/
    ├── build-and-push.sh        # Build → tag → push to ACR
    └── deploy.sh                # Apply infra → monitoring → kustomize overlay
```

## Azure-Specific Features

### Storage Classes

| Class | SKU | Use Case | Reclaim |
|-------|-----|----------|---------|
| `azure-premium-ssd` | Premium_LRS | Postgres (production) | Retain |
| `azure-standard-ssd` | StandardSSD_LRS | Transient/low-priority data | Delete |

Postgres uses `azure-premium-ssd` via `volumeClaimTemplates` with `WaitForFirstConsumer` binding (pod scheduled before PV provisioned).

### Network Policies

- `default-deny-ingress` — deny all inbound by default
- `allow-intra-namespace` — allow traffic within `mytutorial`
- `allow-azure-lb-health-probes` — allow `168.63.129.16/32` (Azure LB probe IP) on port 8080
- `allow-prometheus-scrape` — allow Prometheus pod to scrape `/actuator/prometheus`

### Application Gateway Ingress (AGIC)

The base ingress targets Azure Application Gateway. To enable:

1. Deploy AGIC add-on to AKS:
   ```bash
   az aks enable-addons \
     --resource-group $RG \
     --name $AKS \
     --addons ingress-appgw \
     --appgw-name mytutorial-appgw \
     --appgw-subnet-cidr 10.2.0.0/16
   ```

2. Replace `api.mytutorial.example.com` with your domain in `base/ingress.yaml`
3. Create TLS secret or use Key Vault integration

### Managed Identities (Optional)

For pods needing Azure resources (Key Vault, DB):

```bash
# Enable OIDC issuer
az aks update --resource-group $RG --name $AKS --enable-oidc-issuer

# Create user-assigned managed identity
az identity create --resource-group $RG --name mytutorial-pod-identity
```

## Environment Overlays

| Env | Replicas | HPA min→max | Notes |
|-----|----------|-------------|-------|
| dev | 1 | 1→3 | Single-node dev |
| staging | 2 | 2→10 | Standard resources |
| prod | 3 | 3→15 | Notification=2 replicas, HPA 2→8 |

## Rolling Updates & Rollbacks

```bash
# Restart deployment with new image
kubectl rollout restart deployment/auth-service -n mytutorial

# Monitor
kubectl rollout status deployment/auth-service -n mytutorial

# Rollback
kubectl rollout undo deployment/auth-service -n mytutorial
```

## Monitoring

Prometheus auto-discovers metrics from all pods annotated with `prometheus.io/scrape: "true"`. For Azure-native monitoring:

```bash
# Enable Container Insights (Azure Monitor)
az aks enable-addons \
  --resource-group $RG \
  --name $AKS \
  --addons monitoring

# Or deploy Prometheus via Helm
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack
```

## Clean Up

```bash
# Delete entire deployment
kubectl delete namespace mytutorial

# Delete AKS cluster and all resources
az group delete --name $RG --yes --no-wait
```

## Cost Estimates (approximate, eastus)

| Resource | SKU | Est. Monthly Cost |
|----------|-----|------------------|
| AKS cluster (3x DS2_v2) | Standard | ~$250 |
| ACR (Basic) | Basic | ~$5 |
| Premium SSD (10Gi) per Postgres | P10 | ~$6 |
| Application Gateway v2 | WAF_v2 | ~$90 |
| Standard Load Balancer | Standard | ~$20 |
| **Total (estimate)** | | **~$370/mo** |
