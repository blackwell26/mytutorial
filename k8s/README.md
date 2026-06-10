# MyTutorial - Kubernetes Deployment Guide

## Architecture

All 5 backend services run as scalable Kubernetes Deployments with:
- **HorizontalPodAutoscaler** — auto-scale based on CPU/memory utilization
- **RollingUpdate strategy** — zero-downtime deployments (maxUnavailable=0)
- **Liveness + Readiness probes** — health-aware traffic routing
- **PodDisruptionBudget** — at least 1 pod stays up during voluntary disruptions
- **NetworkPolicies** — restrict ingress traffic per environment

## Prerequisites

- Kubernetes cluster (v1.28+)
- kubectl configured
- Container registry accessible from cluster
- (Optional) Helm for Prometheus/Grafana/Loki

## Directory Structure

```
k8s/
├── base/                  # Base manifests (shared across environments)
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── configmaps.yaml
│   ├── deployments.yaml
│   ├── services.yaml
│   ├── hpas.yaml
│   ├── pdbs.yaml
│   └── network-policies.yaml
├── overlays/
│   ├── dev/               # Dev: 1 replica, HPA 1-3
│   ├── staging/           # Staging: 2 replicas, standard resources
│   └── prod/              # Prod: 3 replicas, HPA 3-15
├── infrastructure/        # Postgres, Redis, Kafka (StatefulSets)
├── monitoring/            # Prometheus, OpenSearch, Logstash, Grafana
└── scripts/
    ├── build-and-push.sh/bat
    └── deploy.sh
```

## Quick Start

```bash
# 1. Build and push Docker images to your registry
REGISTRY=myregistry.io/tag:latest ./k8s/scripts/build-and-push.sh

# 2. Update image tags in k8s/base/deployments.yaml or overlay patches

# 3. Deploy to dev
kubectl create namespace mytutorial
./k8s/scripts/deploy.sh dev

# 4. Watch pods come up
kubectl get pods -n mytutorial -w
```

## Environment Overlays

| Env  | Replicas | HPA min→max | Resources        |
|------|----------|-------------|-------------------|
| dev  | 1        | 1→3         | base              |
| staging | 2     | base→10     | medium requests   |
| prod | 3        | 3→15        | standard limits   |

## Scaling

Each scalable service (auth, grades, gateway) has an HPA that triggers at:
- **70% CPU** utilization
- **80% Memory** utilization

```bash
# Check HPA status
kubectl get hpa -n mytutorial

# Manually scale (if HPA is disabled)
kubectl scale deployment/auth-service --replicas=5 -n mytutorial
```

## Rollout

```bash
# Rolling update (update image tag, then)
kubectl rollout restart deployment auth-service -n mytutorial

# Monitor rollout
kubectl rollout status deployment auth-service -n mytutorial

# Rollback
kubectl rollout undo deployment auth-service -n mytutorial
```

## Access

```bash
# Port-forward to gateway
kubectl port-forward service/api-gateway 8080:80 -n mytutorial

# Or if using LoadBalancer
kubectl get svc api-gateway -n mytutorial
```