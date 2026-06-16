# MyTutorial — Serverless Deployment (AWS Lambda + API Gateway)

Deploy MyTutorial as a fully serverless application on AWS: Spring Boot microservices as Lambda functions behind API Gateway HTTP API, Aurora Serverless PostgreSQL, ElastiCache Serverless Redis, EventBridge for async events.

## Architecture

```
                         ┌──────────────────────────────────────────┐
                         │        Amazon API Gateway HTTP API       │
                         │  /api/signin (POST — no auth)            │
                         │  /api/signup (POST — no auth)            │
                         │  /api/grades (GET  — JWT auth)           │
                         │  /api/grades/{n} (GET — JWT auth)        │
                         └──────────┬──────────────────────┬────────┘
                                    │ JWT auth             │ no auth
                           ┌────────▼────────┐   ┌─────────▼──────────┐
                           │ Lambda Authorizer│   │                    │
                           │ (Node.js, HS512) │   │                    │
                           └────────┬────────┘   │                    │
                      context:      │            │                    │
                      {username}    │            │                    │
                           ┌────────▼────────┐   │                    │
                           │                 │   │                    │
         ┌─────────────────┤   Auth Service  ◄───┘                    │
         │ EventBridge     │   Lambda (:8080)│                        │
         │ (PutEvents)     │                 │                        │
         │                 └────────┬────────┘                        │
         │                          │                                  │
         ▼               ┌──────────▼──────────┐                      │
┌────────────────┐       │                     │                      │
│ Notification   │       │   Grades Service    │◄─────────────────────┘
│ Service Lambda │       │   Lambda (:8080)    │  X-Authenticated-User
│ (EventBridge   │       │                     │  header injected by
│  target)       │       └─────┬───────────┬───┘  Lambda Authorizer
│                │             │           │
│ Email via SES  │    ┌────────▼──┐  ┌─────▼──────┐
│                │    │ Aurora    │  │ ElastiCache │
└────────────────┘    │ Serverless│  │ Serverless  │
                      │ v2 (PG16) │  │ Redis 7     │
                      └───────────┘  └─────────────┘
```

## What Changes vs Traditional Deploy

| Aspect | K8s / Docker | Serverless |
|--------|-------------|------------|
| **Compute** | EC2 + Docker + K8s | Lambda (provided.al2023) |
| **API Gateway** | nginx / Spring Cloud Gateway | **Amazon API Gateway HTTP API** |
| **Auth** | JwtAuthenticationFilter in gateway | **Lambda Authorizer** (Node.js) |
| **Service Discovery** | Eureka | Removed (no need — single API Gateway) |
| **Message Bus** | Kafka | **Amazon EventBridge** |
| **Database** | Postgres StatefulSet (5Gi PVC) | **Aurora Serverless v2** (0.5–4 ACU) |
| **Cache** | Redis Deployment | **ElastiCache Serverless Redis** |
| **Email** | SMTP via Gmail | **Amazon SES** |
| **Networking** | ClusterIP / LoadBalancer | **VPC + Private Subnets + VPC Endpoints** |
| **Images** | JARs in Docker containers | Lambda container images in **ECR** |

## Directory Structure

```
deploy-serverless/
├── template.yaml                       # SAM template (all resources)
├── services/
│   ├── auth-service/
│   │   ├── Dockerfile                  # Lambda container image build
│   │   └── application-serverless.yml  # Spring profile (Aurora, ElastiCache, EventBridge)
│   ├── grades-service/
│   │   ├── Dockerfile
│   │   └── application-serverless.yml
│   └── notification-service/
│       ├── Dockerfile
│       └── application-serverless.yml
├── authorizer/
│   ├── package.json
│   └── index.js                        # JWT Lambda Authorizer (HS512)
├── scripts/
│   ├── build.sh                        # Docker build → ECR push
│   └── deploy.sh                       # SAM package → deploy
└── README.md
```

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| AWS CLI | v2 | Authenticate, deploy |
| SAM CLI | v1.120+ | Build and deploy |
| Docker | 24+ | Build Lambda container images |
| Java | 21 | Local build (or use Docker) |
| Maven | 3.9+ | Local build |

```bash
# Install SAM CLI
wget https://github.com/aws/aws-sam-cli/releases/latest/download/aws-sam-cli-linux-x86_64.zip
unzip aws-sam-cli-linux-x86_64.zip -d sam-install && sudo ./sam-install/install

# Verify
sam --version
aws sts get-caller-identity  # Must be authenticated
```

## Quick Start

### 1. Build and push Lambda images

```bash
export AWS_REGION=us-east-1
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export ECR_REPO_PREFIX=mytutorial

./deploy-serverless/scripts/build.sh dev
```

### 2. Deploy the SAM stack

```bash
./deploy-serverless/scripts/deploy.sh dev
```

Deployment takes **15–20 minutes** (Aurora cluster provisioning is the slowest part).

### 3. Test

```bash
# Get the API endpoint
API_URL=$(aws cloudformation describe-stacks \
  --stack-name mytutorial-serverless-dev \
  --query "Stacks[0].Outputs[?OutputKey=='ApiEndpoint'].OutputValue" \
  --output text)

# Sign up
curl -X POST "${API_URL}/api/signup" \
  -H 'Content-Type: application/json' \
  -d '{"username":"alice","email":"alice@test.com","password":"password123","firstName":"Alice"}'

# Sign in
RESP=$(curl -s -X POST "${API_URL}/api/signin" \
  -H 'Content-Type: application/json' \
  -d '{"username":"alice","password":"password123"}')
TOKEN=$(echo "$RESP" | jq -r '.token')

# List grades (authenticated)
curl "${API_URL}/api/grades" \
  -H "Authorization: Bearer ${TOKEN}"

# Single grade
curl "${API_URL}/api/grades/1" \
  -H "Authorization: Bearer ${TOKEN}"
```

## AWS Resources Created

| Resource | Type | Configuration |
|----------|------|---------------|
| **VPC** | AWS::EC2::VPC | 10.0.0.0/16, 2 private subnets |
| **VPC Endpoints** | 7× AWS::EC2::VPCEndpoint | S3, DynamoDB, ECR (dkr+api), Logs, Events, Secrets Manager |
| **API Gateway** | AWS::Serverless::HttpApi | HTTP API, CORS enabled, $default stage |
| **Lambda Authorizer** | AWS::Serverless::Function | Node.js 20, 256MB, JWT validation (HS512) |
| **Auth Service** | AWS::Serverless::Function | Spring Boot on Lambda Web Adapter, 1536MB |
| **Grades Service** | AWS::Serverless::Function | Spring Boot on Lambda Web Adapter, 1024MB |
| **Notification Service** | AWS::Serverless::Function | Spring Boot on Lambda Web Adapter, 512MB |
| **EventBridge Bus** | AWS::Events::EventBus | Custom event bus `mytutorial-{env}-auth-events` |
| **Aurora Serverless v2** | AWS::RDS::DBCluster | PostgreSQL 16, 0.5-4 ACU, 7-day backup |
| **ElastiCache Serverless** | AWS::ElastiCache::ServerlessCache | Redis 7, max 10GB, max 2000 ECPU/s |
| **KMS Key** | AWS::KMS::Key | For ElastiCache encryption |

## Costs (approximate)

| Service | Config | Est. Monthly |
|---------|--------|-------------|
| Lambda (3 functions) | 1M invocations, 1s avg, 1GB | ~$5 |
| API Gateway HTTP API | 1M requests | ~$1 |
| Aurora Serverless v2 | 0.5 ACU avg, 50GB storage | ~$15 |
| ElastiCache Serverless | 1GB data, minimal ECPU | ~$20 |
| VPC Endpoints (7) | Gateway + Interface | ~$15 |
| ECR storage | 3 images, ~2GB total | ~$0.50 |
| **Total** | | **~$56/mo** |

Compare to `deploy-EC2` (~$80–120/mo for `t3.medium`) or `deploy-azure` (~$370/mo).

## Lambda Cold Starts

Spring Boot on Lambda has cold start latency. Using Lambda Web Adapter with the provided.al2023 runtime:

| Function | Memory | Cold Start (P50) | Warm (P50) |
|----------|--------|-----------------|------------|
| Auth Service | 1536MB | ~3-5s | ~100ms |
| Grades Service | 1024MB | ~2-4s | ~80ms |
| Notification Service | 512MB | ~2-3s | ~50ms |

**Mitigations:**
- Provisioned Concurrency (adds cost): `ProvisionedConcurrencyConfig: { ProvisionedConcurrentExecutions: 1 }`
- SnapStart (Java 11/17 only — Java 21 not yet supported for container images)
- Reserve concurrency to avoid noisy-neighbor cold starts

## Event Flow (Replacing Kafka)

```
Auth Service (same Lambda)
  │
  │  EventBridge.putEvents({
  │    Entries: [{
  │      EventBusName: "mytutorial-dev-auth-events",
  │      Source: "com.mytutorial.auth",
  │      DetailType: "USER_REGISTERED",  // or USER_SIGNED_IN
  │      Detail: JSON.stringify({ username, email, firstName, timestamp })
  │    }]
  │  })
  ▼
┌────────────────────────────────┐
│  Amazon EventBridge            │
│  matches detail-type pattern   │
└──────────┬─────────────────────┘
           │
           ▼
Notification Service (target Lambda)
  │  Parses event.detail
  │  Sends email via SES
  ▼
Email delivered to user
```

The auth-service's `AuthEventProducer` is modified to call `EventBridge.putEvents()` instead of Kafka producer. The notification-service removes its Kafka consumer and instead receives the EventBridge payload directly as a Lambda invocation.

## Environment Overlays

The SAM `Environment` parameter controls:

| Aspect | dev | staging | prod |
|--------|-----|---------|------|
| Aurora ACU range | 0.5–2 | 0.5–4 | 1–16 |
| Lambda memory (auth) | 1024MB | 1536MB | 2048MB |
| Lambda memory (grades) | 768MB | 1024MB | 1536MB |
| Lambda memory (notif) | 512MB | 768MB | 1024MB |
| Backup retention | 1 day | 7 days | 35 days |
| Deletion protection | false | false | true |
| Provisioned concurrency | 0 | 0 | 1 (auth + grades) |

To customize per environment, add `Parameters/` overrides in the SAM template.

## Clean Up

```bash
aws cloudformation delete-stack --stack-name mytutorial-serverless-dev

# Delete ECR images
for svc in auth-service grades-service notification-service; do
  aws ecr batch-delete-image \
    --repository-name mytutorial-dev-${svc} \
    --image-ids imageTag=latest
done
```

## Known Limitations

1. **No custom domain** — Uses the default `execute-api` endpoint. Add a custom domain via `AWS::ApiGatewayV2::DomainName`.
2. **Lambda cold starts** — Spring Boot is heavy for Lambda. Consider Spring Cloud Function for lower latency, or Provisioned Concurrency for production.
3. **No WebSocket** — API Gateway HTTP API supports WebSocket, but the services don't use it yet.
4. **Single instance** — Each Lambda runs one service; auth-service and grades-service share Aurora+Redis but are independent functions.
5. **EventBridge retry** — If notification-service fails, EventBridge retries up to 24h by default (configurable via `RetryPolicy`).
