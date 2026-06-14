# MyTutorial — Local OpenShift Deployment (deploy-local-oc)

Deploys MyTutorial to a **local OpenShift** cluster (e.g. CodeReady Containers / OpenShift Local).

## Quick Start

```bash
# 1. Ensure logged into OpenShift
oc login -u kubeadmin https://api.crc.testing:6443

# 2. Build images and push to OpenShift internal registry
./scripts/build-local-oc.sh

# 3. Deploy everything
./scripts/deploy-local-oc.sh dev

# 4. Get the route URL
oc get route api-gateway -n mytutorial --template='https://{{ .spec.host }}'
```

## Requirements

- OpenShift cluster (CRC / OpenShift Local recommended)
- `oc` CLI logged in with cluster-admin privileges
- `docker` CLI
- `kustomize` CLI

## Scripts

| Script | Purpose |
|--------|---------|
| `build-local-oc.sh` | Builds all 5 service images via host Docker and pushes to OpenShift internal registry |
| `deploy-local-oc.sh [env]` | Creates project → sets up SA+SCC → creates ImageStreams → deploys infrastructure → deploys app via kustomize |
| `rebuild-service.sh <svc>` | Rebuilds and pushes one service image, triggers rollout |
| `reset-local-oc.sh` | Deletes the entire project (all resources, PVCs, configs) |

## Structure

```
deploy-local-oc/
├── base/                      # Base Kustomize resources
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── serviceaccount.yaml
│   ├── imagestreams.yaml
│   ├── configmaps.yaml
│   ├── deploymentconfigs.yaml
│   ├── services.yaml
│   ├── routes.yaml
│   ├── hpas.yaml
│   ├── pdbs.yaml
│   └── network-policies.yaml
├── overlays/                  # Environment overlays
│   ├── dev/
│   ├── staging/
│   └── prod/
├── infrastructure/            # Infrastructure manifests
│   ├── postgres.yaml
│   ├── redis.yaml
│   └── kafka.yaml
├── scripts/
│   ├── build-local-oc.sh
│   ├── deploy-local-oc.sh
│   ├── rebuild-service.sh
│   └── reset-local-oc.sh
└── README.md
```

## Build/Deploy Details

### Build Process
1. `build-local-oc.sh` builds all 5 services from `backend/` using host Docker
2. Images are tagged with git SHA + `latest`
3. Images are pushed to OpenShift internal registry (`image-registry.openshift-image-registry.svc:5000`)
4. ImageStreams are tagged to make them available for DeploymentConfig triggers

### Deployment Order
1. Project namespace created
2. Service account + anyuid SCC for JRE compatibility
3. ImageStreams for all 5 services
4. Infrastructure: PostgreSQL (StatefulSet), Redis (Deployment), Kafka+Zookeeper (StatefulSet)
5. Application via Kustomize: DeploymentConfigs with ImageChange triggers, Services (headless), Routes (edge TLS), HPAs, PDBs, NetworkPolicies

### Rebuilding a Single Service
```bash
./scripts/rebuild-service.sh auth-service
```
This rebuilds the image, pushes to registry, and triggers a rollout via `oc rollout latest`.

### Environment Overrides

| Environment | Replicas (app) | HPA min/max |
|------------|----------------|-------------|
| dev        | 1 (all)        | 1-3         |
| staging    | 2 (auth,grades,gateway), 1 (eureka,notification) | 2-5 |
| prod       | 3 (auth,grades,gateway), 2 (notification) | 3-10 / 2-5 |