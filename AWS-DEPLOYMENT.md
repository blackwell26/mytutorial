# Deploying & Managing Containerized Applications in AWS

This guide covers how to deploy the MyTutorial microservices stack on AWS using containers, covering two primary paths: **Amazon ECS** (simpler, fully managed) and **Amazon EKS** (Kubernetes-native, portable). It also covers CI/CD pipelines, networking, observability, and day-2 operations.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [Container Registry — Amazon ECR](#3-container-registry--amazon-ecr)
4. [Option A: Deploy on Amazon ECS (Fargate)](#4-option-a-deploy-on-amazon-ecs-fargate)
5. [Option B: Deploy on Amazon EKS](#5-option-b-deploy-on-amazon-eks)
6. [CI/CD Pipeline with GitHub Actions](#6-cicd-pipeline-with-github-actions)
7. [Networking & Security](#7-networking--security)
8. [Observability](#8-observability)
9. [Auto-Scaling](#9-auto-scaling)
10. [Day-2 Operations](#10-day-2-operations)
11. [Cost Optimization](#11-cost-optimization)
12. [Troubleshooting](#12-troubleshooting)

---

## 1. Architecture Overview

```
                         ┌──────────────┐
                         │   Route 53   │
                         │  mytutorial.io│
                         └──────┬───────┘
                                │
                         ┌──────▼───────┐
                         │ CloudFront   │
                         │ (CDN / WAF)  │
                         └──────┬───────┘
                                │
                   ┌────────────┼────────────┐
                   │            │            │
          ┌────────▼───┐ ┌─────▼──────┐ ┌───▼────────┐
          │  ALB (SSL) │ │  S3 Static │ │ Cognito    │
          │  /api/*    │ │  Frontend  │ │ Auth       │
          └─────┬──────┘ └────────────┘ └────────────┘
                │
        ┌───────┼───────────────┐
        │       │               │
  ┌─────▼──┐ ┌─▼──────┐  ┌─────▼─────┐
  │ ECS /  │ │ ECS /  │  │  ECS /    │
  │ EKS    │ │ EKS    │  │  EKS      │
  │ Gateway│ │ Auth   │  │  Grades   │
  └───┬────┘ └───┬────┘  └─────┬─────┘
      │          │              │
      │    ┌─────▼──────┐      │
      │    │  ECS / EKS │      │
      │    │  Notif.    │      │
      │    └─────┬──────┘      │
      │          │             │
      └─────┬────┼─────────────┘
            │    │
       ┌────▼────▼──┐   ┌───────┐   ┌───────────┐
       │ RDS        │   │ Elasti│   │ MSK       │
       │ PostgreSQL │   │Cache  │   │ (Kafka)   │
       └────────────┘   │(Redis)│   └───────────┘
                        └───────┘
```

### AWS Services Used

| Component | AWS Service | Purpose |
|-----------|-------------|---------|
| **Compute** | ECS (Fargate) or EKS (EC2/Fargate) | Run containers |
| **Registry** | ECR | Store Docker images |
| **Load Balancer** | ALB (Application Load Balancer) | Route traffic to services |
| **DNS** | Route 53 | Domain name resolution |
| **Database** | RDS for PostgreSQL | Persistent data |
| **Cache** | ElastiCache for Redis | Session caching |
| **Streaming** | MSK (Managed Streaming for Kafka) | Event bus |
| **Secrets** | Secrets Manager | JWT secrets, DB passwords |
| **Monitoring** | CloudWatch, X-Ray, Prometheus | Observability |
| **Certificate** | ACM (Certificate Manager) | TLS/SSL |
| **CDN** | CloudFront | Frontend static assets |
| **IAM** | IAM roles & policies | Service permissions |

---

## 2. Prerequisites

### Tools
- AWS CLI configured (`aws configure`)
- Docker
- kubectl + eksctl (for EKS only)
- GitHub CLI (for CI/CD setup)

### Bootstrap Infrastructure (one-time)

```bash
# Create ECR repositories for each service
for svc in eureka-server auth-service grades-service notification-service api-gateway; do
  aws ecr create-repository \
    --repository-name "mytutorial/$svc" \
    --image-scanning-configuration scanOnPush=true \
    --region us-east-1
done

# Create Secrets Manager secrets
aws secretsmanager create-secret \
  --name /mytutorial/jwt-secret \
  --secret-string "3f8a2b1c9d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a"

aws secretsmanager create-secret \
  --name /mytutorial/db-password \
  --secret-string "mypassword"

# Create RDS PostgreSQL
aws rds create-db-instance \
  --db-instance-identifier mytutorial-postgres \
  --db-instance-class db.t4g.micro \
  --engine postgres \
  --master-username postgres \
  --master-user-password "$(aws secretsmanager get-secret-value --secret-id /mytutorial/db-password --query SecretString --output text)" \
  --allocated-storage 20 \
  --publicly-accessible false

# Create ElastiCache Redis
aws elasticache create-cache-cluster \
  --cache-cluster-id mytutorial-redis \
  --cache-node-type cache.t4g.micro \
  --engine redis \
  --num-cache-nodes 1

# Create MSK Kafka cluster
aws kafka create-cluster \
  --cluster-name mytutorial-kafka \
  --kafka-version 2.8.1 \
  --number-of-broker-nodes 2 \
  --broker-node-group-info "InstanceType=kafka.t3.small,ClientSubnets=..."
```

---

## 3. Container Registry — Amazon ECR

### Authentication & Push

```bash
# Authenticate Docker to ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  "$(aws sts get-caller-identity --query Account --output text).dkr.ecr.us-east-1.amazonaws.com"

# Tag and push images
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="$ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com"
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

### Image Security
- **`scanOnPush=true`** — ECR automatically scans for CVEs on push
- **Image lifecycle policies** — auto-expire old images
- **Cross-account replication** for DR

```bash
aws ecr put-lifecycle-policy \
  --repository-name mytutorial/auth-service \
  --lifecycle-policy-text '{
    "rules": [{
      "rulePriority": 1,
      "description": "Keep last 10 images",
      "selection": {
        "tagStatus": "any",
        "countType": "imageCountMoreThan",
        "countNumber": 10
      },
      "action": { "type": "expire" }
    }]
  }'
```

---

## 4. Option A: Deploy on Amazon ECS (Fargate)

ECS Fargate is the **simplest** path — no cluster management, no Kubernetes overhead. Each service runs as a Fargate task behind an ALB.

### 4.1 Task Definitions

Each microservice gets a task definition. Example for `auth-service`:

```json
{
  "family": "mytutorial-auth-service",
  "taskRoleArn": "arn:aws:iam::ACCOUNT_ID:role/mytutorial-ecs-task-role",
  "executionRoleArn": "arn:aws:iam::ACCOUNT_ID:role/mytutorial-ecs-execution-role",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "512",
  "memory": "1024",
  "containerDefinitions": [
    {
      "name": "auth-service",
      "image": "ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/mytutorial/auth-service:latest",
      "portMappings": [{ "containerPort": 8081, "protocol": "tcp" }],
      "environment": [
        { "name": "SPRING_PROFILES_ACTIVE", "value": "k8s" },
        { "name": "EUREKA_CLIENT_SERVICEURL_DEFAULTZONE", "value": "http://eureka-server:8761/eureka/" },
        { "name": "SPRING_DATASOURCE_URL", "value": "jdbc:postgresql://mytutorial-postgres.cxxxxx.us-east-1.rds.amazonaws.com:5432/postgres" },
        { "name": "SPRING_DATASOURCE_USERNAME", "value": "postgres" },
        { "name": "SPRING_DATA_REDIS_HOST", "value": "mytutorial-redis.xxxxx.ng.0001.use1.cache.amazonaws.com" },
        { "name": "SPRING_KAFKA_BOOTSTRAP_SERVERS", "value": "b-1.mytutorial-kafka.xxxxx.kafka.us-east-1.amazonaws.com:9092" }
      ],
      "secrets": [
        { "name": "SPRING_DATASOURCE_PASSWORD", "valueFrom": "arn:aws:secretsmanager:us-east-1:ACCOUNT_ID:secret:/mytutorial/db-password" },
        { "name": "APP_JWT_SECRET", "valueFrom": "arn:aws:secretsmanager:us-east-1:ACCOUNT_ID:secret:/mytutorial/jwt-secret" }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/mytutorial/auth-service",
          "awslogs-region": "us-east-1",
          "awslogs-stream-prefix": "ecs"
        }
      },
      "healthCheck": {
        "command": ["CMD-SHELL", "curl -f http://localhost:8081/actuator/health || exit 1"],
        "interval": 15,
        "timeout": 5,
        "retries": 3,
        "startPeriod": 60
      }
    }
  ]
}
```

### 4.2 Service Discovery with Cloud Map

ECS services use **AWS Cloud Map** for service discovery (replaces Eureka):

```bash
# Create a namespace
aws servicediscovery create-private-dns-namespace \
  --name mytutorial.local \
  --vpc vpc-xxxxx

# Register each service
aws servicediscovery create-service \
  --name auth-service \
  --dns-config "NamespaceId=ns-xxxxx,RoutingPolicy=WEIGHTED,DnsRecords=[{Type=A,TTL=10}]"
```

Alternatively, use **ALB + Eureka** if you want to keep the existing discovery mechanism:

```yaml
# Each ECS service registers with Eureka. The ALB points to the gateway.
```

### 4.3 ECS Service Definition

```bash
# Create ECS cluster
aws ecs create-cluster --cluster-name mytutorial

# Create ECS service (auth-service example)
aws ecs create-service \
  --cluster mytutorial \
  --service-name auth-service \
  --task-definition mytutorial-auth-service \
  --desired-count 2 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[subnet-xxx,subnet-yyy],securityGroups=[sg-xxx],assignPublicIp=DISABLED}" \
  --service-connect-configuration '{"enabled":true,"namespace":"mytutorial"}' \
  --deployment-configuration "minimumHealthyPercent=100,maximumPercent=200"
```

### 4.4 ALB for the Gateway

```bash
# Create ALB + target group for api-gateway port 8080
aws elbv2 create-target-group \
  --name mytutorial-gateway-tg \
  --protocol HTTP \
  --port 8080 \
  --vpc vpc-xxxxx \
  --health-check-path /actuator/health \
  --health-check-interval-seconds 30 \
  --target-type ip

# Create listeners + rules for each API path
aws elbv2 create-listener \
  --load-balancer-arn arn:aws:elasticloadbalancing:...:loadbalancer/app/mytutorial/... \
  --protocol HTTPS \
  --port 443 \
  --certificates CertificateArn=arn:aws:acm:...:certificate/... \
  --default-actions Type=forward,TargetGroupArn=arn:aws:elasticloadbalancing:...:targetgroup/mytutorial-gateway-tg/...
```

### 4.5 ECS Full Deployment Script

```bash
#!/bin/bash
# deploy-ecs.sh
set -euo pipefail

CLUSTER="mytutorial"
REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
TAG=$(git rev-parse --short HEAD)

echo "=== Building and pushing images ==="
for svc in eureka-server auth-service grades-service notification-service api-gateway; do
  docker build -f "backend/$svc/Dockerfile" \
    -t "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/mytutorial/$svc:$TAG" ./backend
  docker push "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/mytutorial/$svc:$TAG"
done

echo "=== Registering task definitions ==="
# Each task definition JSON lives in deploy/ecs/task-definitions/
for svc in eureka-server auth-service grades-service notification-service api-gateway; do
  sed "s/IMAGE_TAG/$TAG/g" "deploy/ecs/task-definitions/$svc.json" > /tmp/task-def.json
  aws ecs register-task-definition --cli-input-json file:///tmp/task-def.json
done

echo "=== Updating services ==="
for svc in eureka-server auth-service grades-service notification-service api-gateway; do
  aws ecs update-service \
    --cluster "$CLUSTER" \
    --service "$svc" \
    --force-new-deployment \
    --region "$REGION"
done

echo "=== Deployment complete ==="
```

---

## 5. Option B: Deploy on Amazon EKS

Use the existing `k8s/` manifests directly on EKS for full Kubernetes-native portability.

### 5.1 Create EKS Cluster

```bash
# Create cluster with managed node groups
eksctl create cluster \
  --name mytutorial \
  --region us-east-1 \
  --version 1.30 \
  --nodegroup-name standard \
  --node-type t3.medium \
  --nodes 3 \
  --nodes-min 3 \
  --nodes-max 10 \
  --managed \
  --with-oidc \
  --full-ecr-access \
  --alb-ingress-controller

# Update kubeconfig
aws eks update-kubeconfig --region us-east-1 --name mytutorial
```

### 5.2 Create Namespace

```bash
kubectl create namespace mytutorial
```

### 5.3 Set Up ECR Pull Access

```bash
# Associate IAM OIDC provider
eksctl utils associate-iam-oidc-provider \
  --cluster mytutorial \
  --approve

# Create IAM role for service accounts (IRSA)
eksctl create iamserviceaccount \
  --cluster mytutorial \
  --namespace mytutorial \
  --name mytutorial-sa \
  --attach-policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly \
  --override-existing-serviceaccounts \
  --approve
```

### 5.4 Deploy Infrastructure (RDS, ElastiCache, MSK)

Deploy AWS-managed infrastructure, then reference endpoints in ConfigMaps:

```bash
# Get RDS endpoint
RDS_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier mytutorial-postgres \
  --query 'DBInstances[0].Endpoint.Address' --output text)

# Get ElastiCache endpoint
REDIS_ENDPOINT=$(aws elasticache describe-cache-clusters \
  --cache-cluster-id mytutorial-redis \
  --query 'CacheClusters[0].ConfigurationEndpoint.Address' --output text)

# Get MSK bootstrap brokers
KAFKA_BROKERS=$(aws kafka get-bootstrap-brokers \
  --cluster-arn $(aws kafka list-clusters --query 'ClusterInfoList[0].ClusterArn' --output text) \
  --query BootstrapBrokerString --output text)

# Apply ConfigMap with correct endpoints
cat <<EOF | kubectl apply -n mytutorial -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: mytutorial-shared
data:
  EUREKA_CLIENT_SERVICEURL_DEFAULTZONE: "http://eureka-server:8761/eureka/"
  SPRING_DATASOURCE_URL: "jdbc:postgresql://$RDS_ENDPOINT:5432/postgres"
  SPRING_DATA_REDIS_HOST: "$REDIS_ENDPOINT"
  SPRING_KAFKA_BOOTSTRAP_SERVERS: "$KAFKA_BROKERS"
  LOGGING_LOGSTASH_HOST: "logstash"
  LOGGING_LOGSTASH_PORT: "5000"
EOF
```

### 5.5 Deploy with Kustomize

```bash
# Build and apply with Kustomize
kustomize build k8s/overlays/prod | kubectl apply -n mytutorial -f -

# Or use kubectl directly (1.28+ has built-in kustomize)
kubectl apply -k k8s/overlays/prod --namespace mytutorial
```

### 5.6 Set Up ALB Ingress for the Gateway

```bash
# Deploy AWS Load Balancer Controller
eksctl utils associate-iam-oidc-provider --cluster mytutorial --approve

eksctl create iamserviceaccount \
  --cluster mytutorial \
  --namespace kube-system \
  --name aws-load-balancer-controller \
  --attach-policy-arn arn:aws:iam::ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy \
  --override-existing-serviceaccounts \
  --approve

# Install with Helm
helm repo add eks https://aws.github.io/eks-charts
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=mytutorial \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller

# Create Ingress for the API Gateway
cat <<EOF | kubectl apply -n mytutorial -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: api-gateway
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:us-east-1:ACCOUNT_ID:certificate/xxxxx
    alb.ingress.kubernetes.io/healthcheck-path: /actuator/health
    alb.ingress.kubernetes.io/success-codes: "200-399"
spec:
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
EOF
```

---

## 6. CI/CD Pipeline with GitHub Actions

### 6.1 Workflow: Build, Test, Push, Deploy

```yaml
# .github/workflows/deploy-aws.yml
name: Deploy to AWS

on:
  push:
    branches: [main, develop]
    paths:
      - 'backend/**'
  workflow_dispatch:
    inputs:
      environment:
        description: 'Target environment'
        required: true
        default: 'dev'
        type: choice
        options:
          - dev
          - staging
          - prod

env:
  AWS_REGION: us-east-1
  ECR_REGISTRY: ${{ secrets.ACCOUNT_ID }}.dkr.ecr.us-east-1.amazonaws.com
  CLUSTER_NAME: mytutorial

permissions:
  id-token: write
  contents: read

jobs:
  test-and-build:
    name: Test & Build
    runs-on: ubuntu-latest
    outputs:
      tags: ${{ steps.tags.outputs.tags }}

    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-java@v4
        with:
          java-version: '21'
          distribution: 'temurin'
          cache: maven

      - name: Run tests
        run: mvn -B test -q
        working-directory: backend

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::${{ secrets.ACCOUNT_ID }}:role/github-actions-ecr-push
          aws-region: ${{ env.AWS_REGION }}

      - name: Login to Amazon ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build, tag, and push images
        id: tags
        env:
          TAG: ${{ github.sha }}
        run: |
          SERVICES="eureka-server auth-service grades-service notification-service api-gateway"
          TAGS=""
          for svc in $SERVICES; do
            docker build -f "backend/$svc/Dockerfile" \
              -t "$ECR_REGISTRY/mytutorial/$svc:$TAG" \
              -t "$ECR_REGISTRY/mytutorial/$svc:latest" \
              ./backend
            docker push "$ECR_REGISTRY/mytutorial/$svc:$TAG"
            docker push "$ECR_REGISTRY/mytutorial/$svc:latest"
          done
          echo "tags=$TAG" >> $GITHUB_OUTPUT

  deploy-ecs:
    name: Deploy to ECS (${{ github.event.inputs.environment || 'dev' }})
    needs: test-and-build
    runs-on: ubuntu-latest
    environment: ${{ github.event.inputs.environment || 'dev' }}

    steps:
      - uses: actions/checkout@v4

      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::${{ secrets.ACCOUNT_ID }}:role/github-actions-ecs-deploy
          aws-region: ${{ env.AWS_REGION }}

      - name: Update ECS services
        run: |
          for svc in eureka-server auth-service grades-service notification-service api-gateway; do
            aws ecs update-service \
              --cluster "$CLUSTER_NAME" \
              --service "$svc" \
              --force-new-deployment
          done

      - name: Wait for deployments to stabilize
        run: |
          for svc in eureka-server auth-service grades-service notification-service api-gateway; do
            aws ecs wait services-stable \
              --cluster "$CLUSTER_NAME" \
              --services "$svc"
          done
```

### 6.2 GitHub Secrets Required

| Secret | Description |
|--------|-------------|
| `ACCOUNT_ID` | AWS Account ID |
| `AWS_REGION` | Default region |
| GitHub OIDC Role | IAM role for GitHub Actions (see below) |

### 6.3 IAM Roles for GitHub Actions (OIDC)

```bash
# Create OIDC identity provider in AWS IAM
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com

# Create IAM role with trust policy for GitHub Actions
cat > trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:your-org/mytutorial:*"
        }
      }
    }
  ]
}
EOF

aws iam create-role \
  --role-name github-actions-ecr-push \
  --assume-role-policy-document file://trust-policy.json

# Attach policies
aws iam attach-role-policy \
  --role-name github-actions-ecr-push \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser

aws iam attach-role-policy \
  --role-name github-actions-ecs-deploy \
  --policy-arn arn:aws:iam::aws:policy/AmazonECS_FullAccess
```

---

## 7. Networking & Security

### 7.1 VPC Architecture

```
10.0.0.0/16 MyTutorial VPC
├── 10.0.1.0/24  Public Subnet AZ-a  (ALB, NAT Gateway)
├── 10.0.2.0/24  Public Subnet AZ-b
├── 10.0.10.0/24 Private Subnet AZ-a (ECS/EKS tasks, RDS, Redis)
├── 10.0.11.0/24 Private Subnet AZ-b (ECS/EKS tasks, RDS, Redis)
└── 10.0.20.0/24 Private Subnet AZ-c (MSK)
```

### 7.2 Security Groups

| Resource | Inbound | Outbound |
|----------|---------|----------|
| **ALB** | 443 (HTTPS from internet), 80 (HTTP → redirect) | All to ECS/EKS tasks |
| **ECS Tasks** | 8080-8083 from ALB, 8761 from other tasks | All infrastructure |
| **RDS** | 5432 from ECS/EKS | — |
| **ElastiCache** | 6379 from ECS/EKS | — |
| **MSK** | 9092 from ECS/EKS | — |
| **EKS Nodes** | 443 (API Server), 10250 (kubelet) | All |

### 7.3 Secrets Management

```yaml
# In ECS task definitions, use:
"secrets": [
  { "name": "APP_JWT_SECRET",
    "valueFrom": "arn:aws:secretsmanager:us-east-1:xxx:secret:/mytutorial/jwt-secret-xxxxx" }
]

# In EKS, use External Secrets Operator:
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: jwt-secret
spec:
  secretStoreRef:
    name: aws-secretstore
    kind: SecretStore
  target:
    name: mytutorial-secrets
  data:
    - secretKey: APP_JWT_SECRET
      remoteRef:
        key: /mytutorial/jwt-secret
```

### 7.4 Encryption at Rest & In Transit

- **ECR** — encrypted at rest by default (AES-256)
- **RDS** — enable encryption + enforce TLS
- **ElastiCache** — enable encryption in-transit + at-rest
- **MSK** — enable TLS between brokers and clients
- **ALB** — terminate TLS via ACM certificates
- **EBS** (EKS) — enable EBS encryption by default

### 7.5 IAM Best Practices

- Each ECS task gets a **task role** scoped to specific resource access
- EKS uses **IRSA** (IAM Roles for Service Accounts) for pod-level permissions
- Never hardcode AWS credentials — always use instance profiles or IRSA
- Use **AWS Secrets Manager** or **Parameter Store** for app secrets

---

## 8. Observability

### 8.1 CloudWatch (ECS)

ECS containers stream logs to CloudWatch automatically via the `awslogs` driver:

```json
"logConfiguration": {
  "logDriver": "awslogs",
  "options": {
    "awslogs-group": "/ecs/mytutorial/auth-service",
    "awslogs-region": "us-east-1",
    "awslogs-stream-prefix": "ecs",
    "awslogs-create-group": "true"
  }
}
```

**CloudWatch metrics:** CPU, memory, network for each ECS service are collected automatically.

### 8.2 CloudWatch Container Insights (EKS)

```bash
# Enable Container Insights
eksctl utils update-cluster-logging \
  --cluster mytutorial \
  --enable-types all \
  --approve

# Install CloudWatch agent as a DaemonSet
aws iam create-policy \
  --policy-name CloudWatchAgentServerPolicy \
  --policy-document '{
    "Version":"2012-10-17",
    "Statement":[{
      "Effect":"Allow",
      "Action":["cloudwatch:PutMetricData","ec2:DescribeTags","logs:PutLogEvents"],
      "Resource":"*"
    }]
  }'

eksctl create iamserviceaccount \
  --cluster mytutorial \
  --name cloudwatch-agent \
  --namespace amazon-cloudwatch \
  --attach-policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy \
  --approve

# Install CloudWatch agent (using Helm or manifest)
kubectl apply -f https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/quickstart/cwagent-fluentd-quickstart.yaml
```

### 8.3 Prometheus + Grafana (Self-Managed on EKS)

The existing `k8s/monitoring/prometheus.yaml` works on EKS with pod annotation auto-discovery. For production, use **Prometheus Operator** or **AWS Managed Service for Prometheus (AMP)** + **Amazon Managed Grafana (AMG)**:

```bash
# Create Amazon Managed Service for Prometheus (AMP)
aws amp create-workspace --alias mytutorial-prometheus

# Create Amazon Managed Grafana workspace
aws grafana create-workspace \
  --account-access-type CURRENT_ACCOUNT \
  --authentication-providers AWS_SSO \
  --permission-type CUSTOMER_MANAGED \
  --workspace-name mytutorial-grafana
```

```yaml
# Deploy Prometheus agent to send metrics to AMP
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus-agent
spec:
  replicas: 1
  selector:
    matchLabels:
      app: prometheus-agent
  template:
    metadata:
      labels:
        app: prometheus-agent
    spec:
      serviceAccountName: mytutorial-sa
      containers:
        - name: prometheus
          image: prom/prometheus:v2.52
          args:
            - --config.file=/etc/prometheus/prometheus.yml
            - --storage.tsdb.retention.time=1h
            - --export.label.aws_workspace_id=ws-xxxxx
            - --remote-write.url=https://aps-workspaces.us-east-1.amazonaws.com/workspaces/ws-xxxxx/api/v1/remote_write
          volumeMounts:
            - name: config
              mountPath: /etc/prometheus/
      volumes:
        - name: config
          configMap:
            name: prometheus-config
```

### 8.4 AWS X-Ray for Distributed Tracing

```bash
# Add X-Ray daemon as a sidecar or DaemonSet
kubectl apply -n mytutorial -f - <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: xray-daemon
  labels:
    app: xray-daemon
spec:
  selector:
    matchLabels:
      app: xray-daemon
  template:
    metadata:
      labels:
        app: xray-daemon
    spec:
      containers:
        - name: xray-daemon
          image: amazon/aws-xray-daemon
          ports:
            - containerPort: 2000
              protocol: UDP
EOF
```

Update Spring Boot services to send traces to X-Ray:

```xml
<!-- In pom.xml -->
<dependency>
  <groupId>com.amazonaws</groupId>
  <artifactId>aws-xray-recorder-sdk-spring</artifactId>
  <version>2.14.0</version>
</dependency>
<dependency>
  <groupId>com.amazonaws</groupId>
  <artifactId>aws-xray-recorder-sdk-sql-postgres</artifactId>
  <version>2.14.0</version>
</dependency>
```

### 8.5 Dashboards

| Service | Dashboard Content |
|---------|-------------------|
| **CloudWatch Dashboard** | ECS service CPU/memory, ALB request count/5xx, RDS connections |
| **Grafana (managed)** | JVM metrics (heap, GC, threads), HTTP request rate/latency, Kafka consumer lag |
| **X-Ray Console** | Service map, trace timelines, error rates per endpoint |

---

## 9. Auto-Scaling

### 9.1 ECS Service Auto-Scaling

ECS services can scale on CloudWatch metrics:

```bash
# Register scalable target
aws application-autoscaling register-scalable-target \
  --service-namespace ecs \
  --resource-id service/mytutorial/auth-service \
  --scalable-dimension ecs:service:DesiredCount \
  --min-capacity 2 \
  --max-capacity 10

# Scale on CPU
aws application-autoscaling put-scaling-policy \
  --service-namespace ecs \
  --resource-id service/mytutorial/auth-service \
  --scalable-dimension ecs:service:DesiredCount \
  --policy-name cpu-scaling \
  --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration '{
    "TargetValue": 70.0,
    "PredefinedMetricSpecification": {
      "PredefinedMetricType": "ECSServiceAverageCPUUtilization"
    },
    "ScaleOutCooldown": 60,
    "ScaleInCooldown": 120
  }'

# Scale on request count per target
aws application-autoscaling put-scaling-policy \
  --service-namespace ecs \
  --resource-id service/mytutorial/api-gateway \
  --scalable-dimension ecs:service:DesiredCount \
  --policy-name alb-scaling \
  --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration '{
    "TargetValue": 1000.0,
    "PredefinedMetricSpecification": {
      "PredefinedMetricType": "ALBRequestCountPerTarget"
    },
    "ScaleOutCooldown": 30,
    "ScaleInCooldown": 180
  }'
```

### 9.2 EKS Cluster Autoscaler + HPA

The existing `hpas.yaml` (CPU 70% / memory 80%) works with the cluster autoscaler:

```bash
# Deploy Cluster Autoscaler
kubectl apply -f https://raw.githubusercontent.com/kubernetes/autoscaler/master/cluster-autoscaler/cloudprovider/aws/examples/cluster-autoscaler-autodiscover.yaml

# Edit deployment to set your cluster name
kubectl -n kube-system edit deployment cluster-autoscaler
# Add: --node-group-auto-discovery=asg:tag=k8s.io/cluster-autoscaler/enabled,k8s.io/cluster-autoscaler/mytutorial
```

### 9.3 Karpenter (Modern EKS Scaling)

For faster pod startup and cost optimization, use **Karpenter** instead of Cluster Autoscaler:

```bash
# Deploy Karpenter
helm repo add karpenter https://charts.karpenter.sh
helm install karpenter karpenter/karpenter \
  --namespace karpenter \
  --create-namespace \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="arn:aws:iam::xxx:role/karpenter" \
  --set clusterName=mytutorial

# Configure provisioner
kubectl apply -n mytutorial -f - <<EOF
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: default
spec:
  template:
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand", "spot"]
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["t", "c", "m"]
      nodeClassRef:
        name: default
  limits:
    cpu: 40
  disruption:
    consolidationPolicy: WhenUnderutilized
    expireAfter: 720h
---
apiVersion: karpenter.k8s.aws/v1beta1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiFamily: AL2
  role: karpenter-node-role
  subnetSelector:
    karpenter.sh/discovery: mytutorial
  securityGroupSelector:
    karpenter.sh/discovery: mytutorial
  tags:
    karpenter.sh/discovery: mytutorial
EOF
```

---

## 10. Day-2 Operations

### 10.1 Zero-Downtime Deployments

**ECS:** Rolling update with `minimumHealthyPercent=100, maximumPercent=200`

```bash
# Gradual rollout with deployment circuit breaker
aws ecs update-service \
  --cluster mytutorial \
  --service auth-service \
  --deployment-configuration "minimumHealthyPercent=100,maximumPercent=200,deploymentCircuitBreaker={enable=true,rollback=true}" \
  --force-new-deployment
```

**EKS:** RollingUpdate with `maxSurge=1, maxUnavailable=0` (already configured in deployments.yaml)

```bash
# Monitor rollout
kubectl rollout status deployment/auth-service -n mytutorial --watch

# Rollback if needed
kubectl rollout undo deployment/auth-service -n mytutorial

# Use canary deployments with Argo Rollouts (advanced):
# https://argoproj.github.io/rollouts/
```

### 10.2 Backup & Disaster Recovery

```bash
# RDS automated backups (enabled by default with 7-day retention)
aws rds modify-db-instance \
  --db-instance-identifier mytutorial-postgres \
  --backup-retention-period 30 \
  --preferred-backup-window "03:00-04:00"

# Cross-region snapshot copy for DR
aws rds modify-db-instance \
  --db-instance-identifier mytutorial-postgres \
  --backup-target region

# ECR cross-region replication
aws ecr put-replication-configuration \
  --replication-configuration '{
    "rules": [{
      "destinations": [{
        "region": "eu-west-1",
        "registryId": "ACCOUNT_ID"
      }]
    }]
  }'
```

### 10.3 Blue/Green Deployments (ECS)

```bash
# Create a blue/green deployment with CodeDeploy
aws deploy create-application \
  --application-name mytutorial-auth-service \
  --compute-platform ECS

aws deploy create-deployment-group \
  --application-name mytutorial-auth-service \
  --deployment-group-name auth-service-bluegreen \
  --service-role-arn arn:aws:iam::xxx:role/codedeploy-ecs \
  --ecs-services '[{"clusterName":"mytutorial","serviceName":"auth-service"}]' \
  --deployment-style '{"deploymentType":"BLUE_GREEN","deploymentOption":"WITH_TRAFFIC_CONTROL"}' \
  --blue-green-deployment-configuration '{
    "terminateBlueInstancesOnDeploymentSuccess": {
      "action": "TERMINATE",
      "terminationWaitTimeInMinutes": 5
    },
    "deploymentReadyOption": {
      "actionOnTimeout": "STOP_DEPLOYMENT",
      "waitTimeInMinutes": 10
    }
  }' \
  --load-balancer-info '{
    "targetGroupPairInfoList": [{
      "targetGroups": [
        {"name":"mytutorial-auth-v1-tg"},
        {"name":"mytutorial-auth-v2-tg"}
      ],
      "prodTrafficRoute": {"listenerArns":["arn:aws:elasticloadbalancing:...:listener/app/mytutorial/xxx/yyy"]},
      "testTrafficRoute": {"listenerArns":["arn:aws:elasticloadbalancing:...:listener/app/mytutorial/xxx/zzz"]}
    }]
  }'
```

### 10.4 Cost Monitoring

```bash
# Tag all resources
aws ecs tag-resource \
  --resource-arn arn:aws:ecs:us-east-1:xxx:service/mytutorial/auth-service \
  --tags key=Environment,value=prod key=Project,value=mytutorial key=Team,value=platform

# Get cost breakdown by tag via Cost Explorer (CLI)
aws ce get-cost-and-usage \
  --time-period Start=2024-01-01,End=2024-01-31 \
  --granularity MONTHLY \
  --metrics BlendedCost \
  --group-by Type=TAG,Key=Project
```

### 10.5 Patch Management

- **EKS:** `eksctl upgrade cluster` for control plane, managed node groups auto-patch
- **ECS:** Use `latest` tag carefully — pin to specific SHAs for production
- **RDS:** Enable auto-minor-version-upgrade
- **Base images:** Use Dependabot/Renovate to auto-PR Docker image updates

```yaml
# .github/dependabot.yml
version: 2
updates:
  - package-ecosystem: "docker"
    directory: "/backend"
    schedule:
      interval: "weekly"
    commit-message:
      prefix: "chore(deps)"
```

---

## 11. Cost Optimization

| Strategy | Implementation | Estimated Savings |
|----------|---------------|-------------------|
| **Fargate Spot** | Use Fargate Spot for stateless services (auth, grades) | 60-70% vs standard |
| **EKS Spot instances** | Use Karpenter with spot node pools | 60-90% vs on-demand |
| **RDS Graviton** | Use `db.t4g` instead of `db.t3` | 10-20% |
| **RDS Reserved** | 1-year reserved for prod DB | 30-40% |
| **Auto-scaling** | Scale to min at night, max during peak | 40-60% idle waste |
| **Graviton for ECS** | Use ARM64-based Fargate tasks | 20-30% |
| **S3 Lifecycle** | Move frontend assets to Glacier after 30 days | 80% storage cost |
| **CloudWatch** | Set log retention to 7 days for dev, 30 for prod | 50%+ log costs |

```bash
# Use Fargate Spot (ECS)
aws ecs create-service \
  --capacity-provider-strategy "capacityProvider=FARGATE_SPOT,weight=3,base=1" "capacityProvider=FARGATE,weight=1" \
  --service-name grades-service \
  --cluster mytutorial

# Set CloudWatch log retention
for svc in auth-service grades-service notification-service api-gateway eureka-server; do
  aws logs put-retention-policy \
    --log-group-name "/ecs/mytutorial/$svc" \
    --retention-in-days 30
done
```

---

## 12. Troubleshooting

### Pod/Task Won't Start

```bash
# ECS — check stopped reason
aws ecs describe-tasks --cluster mytutorial --tasks $(aws ecs list-tasks --cluster mytutorial --service-name auth-service --desired-status STOPPED --query taskArns --output text)

# EKS — describe pod
kubectl describe pod -n mytutorial auth-service-xxx
kubectl logs -n mytutorial auth-service-xxx --previous

# Common causes:
# - OOMKilled: Container exceeded memory limit → increase limits
# - CrashLoopBackOff: Application crashed → check logs
# - ImagePullBackOff: ECR access issue → check IRSA/execution role
# - Pending: Insufficient cluster capacity → scale up nodes
```

### Database Connection Issues

```bash
# Test connectivity from a jump pod
kubectl run test-pod --image=postgres:16-alpine --rm -it --restart=Never -n mytutorial -- /bin/sh
# Inside the pod:
psql -h mytutorial-postgres.cxxxxx.us-east-1.rds.amazonaws.com -U postgres -d postgres

# Check security group rules
aws ec2 describe-security-groups --group-ids sg-xxx
```

### Performance

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| High latency at gateway | HPA not keeping up | Reduce HPA cooldown to 30s |
| Frequent HPA scale-ups | Request burst > headroom | Add `averageUtilization: 60` |
| OOM kills | Heap > pod memory | Add `-XX:MaxRAMPercentage=75.0` |
| Slow startup on EKS | Container image size | Optimize JRE image with `jlink` |

### Useful Commands

```bash
# ECS
aws ecs list-services --cluster mytutorial
aws ecs describe-services --cluster mytutorial --services api-gateway | jq '.services[].deployments'

# EKS
kubectl get pods -n mytutorial -o wide
kubectl top pods -n mytutorial
kubectl get hpa -n mytutorial -o yaml
kubectl logs -n mytutorial -l app=auth-service --tail=50

# AWS
aws cloudwatch get-metric-statistics --namespace AWS/ECS --metric-name CPUUtilization \
  --dimensions Name=ServiceName,Value=auth-service Name=ClusterName,Value=mytutorial \
  --start-time 2024-01-01T00:00:00 --end-time 2024-01-02T00:00:00 --period 300 \
  --statistics Average
```

---

## Decision Matrix: ECS vs EKS

| Factor | ECS (Fargate) | EKS |
|--------|--------------|-----|
| **Operational overhead** | Minimal — no cluster management | Moderate — control plane + node management |
| **Kubernetes compatibility** | No | Yes — full K8s API |
| **Existing manifests** | Must translate to task definitions | Use `k8s/` manifests directly |
| **Service discovery** | Cloud Map (or Eureka) | CoreDNS + Eureka |
| **Auto-scaling** | Application Auto Scaling | HPA + Cluster Autoscaler/Karpenter |
| **Cost** | Slightly higher per-task | Lower for large workloads |
| **Flexibility** | AWS-native only | Multi-cloud / hybrid |
| **Learning curve** | Lower | Higher |
| **Best for** | Small teams, simpler stacks | Platform teams, consistency with on-prem |

**Recommendation:** Start with **ECS Fargate** for faster time-to-market. Migrate to **EKS** if/when you need multi-cloud portability, advanced K8s features (Istio, Argo), or higher scale at lower cost.

---

## References

- [AWS ECS Developer Guide](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/)
- [AWS EKS User Guide](https://docs.aws.amazon.com/eks/latest/userguide/)
- [AWS ECR Documentation](https://docs.aws.amazon.com/AmazonECR/latest/userguide/)
- [EKS Best Practices](https://aws.github.io/aws-eks-best-practices/)
- [Well-Architected Framework](https://docs.aws.amazon.com/wellarchitected/latest/framework/)