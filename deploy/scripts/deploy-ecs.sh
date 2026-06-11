#!/bin/bash
# deploy-ecs.sh — Build, push, and deploy all services to Amazon ECS Fargate
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────
CLUSTER="${CLUSTER:-mytutorial}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD)}"
SECRET_ARN_DB="${SECRET_ARN_DB}"
SECRET_ARN_JWT="${SECRET_ARN_JWT}"
RDS_ENDPOINT="${RDS_ENDPOINT}"
REDIS_ENDPOINT="${REDIS_ENDPOINT}"
KAFKA_BROKERS="${KAFKA_BROKERS}"

SERVICES=("eureka-server" "auth-service" "grades-service" "notification-service" "api-gateway")

# ── Pre-flight checks ──────────────────────────────────────────────────────
for var in ACCOUNT_ID RDS_ENDPOINT REDIS_ENDPOINT KAFKA_BROKERS SECRET_ARN_DB SECRET_ARN_JWT; do
  if [ -z "${!var}" ]; then
    echo "ERROR: $var is not set"
    exit 1
  fi
done

# ── Login ──────────────────────────────────────────────────────────────────
echo "=== Logging into ECR ==="
aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin "$ECR_REGISTRY"

# ── Build and push ─────────────────────────────────────────────────────────
echo "=== Building and pushing images (tag: $TAG) ==="
for svc in "${SERVICES[@]}"; do
  echo "--- $svc ---"
  docker build \
    -f "backend/$svc/Dockerfile" \
    -t "$ECR_REGISTRY/mytutorial/$svc:$TAG" \
    -t "$ECR_REGISTRY/mytutorial/$svc:latest" \
    ./backend
  docker push "$ECR_REGISTRY/mytutorial/$svc:$TAG"
  docker push "$ECR_REGISTRY/mytutorial/$svc:latest"
done

# ── Register task definitions ──────────────────────────────────────────────
echo "=== Registering task definitions ==="
for svc in "${SERVICES[@]}"; do
  echo "--- $svc ---"
  sed -e "s|\${ECR_REGISTRY}|$ECR_REGISTRY|g" \
      -e "s|\${IMAGE_TAG}|$TAG|g" \
      -e "s|\${AWS_REGION}|$AWS_REGION|g" \
      -e "s|\${RDS_ENDPOINT}|$RDS_ENDPOINT|g" \
      -e "s|\${REDIS_ENDPOINT}|$REDIS_ENDPOINT|g" \
      -e "s|\${KAFKA_BROKERS}|$KAFKA_BROKERS|g" \
      -e "s|\${SECRET_ARN_DB}|$SECRET_ARN_DB|g" \
      -e "s|\${SECRET_ARN_JWT}|$SECRET_ARN_JWT|g" \
      "deploy/ecs/task-definitions/$svc.json" > "/tmp/taskdef-$svc.json"

  aws ecs register-task-definition \
    --family "mytutorial-$svc" \
    --cli-input-json "{\"taskDefinitionArn\":\"\",\"containerDefinitions\":$(cat /tmp/taskdef-$svc.json),\"family\":\"mytutorial-$svc\",\"networkMode\":\"awsvpc\",\"requiresCompatibilities\":[\"FARGATE\"],\"cpu\":\"$(jq -r '.[0].cpu' /tmp/taskdef-$svc.json)\",\"memory\":\"$(jq -r '.[0].memory' /tmp/taskdef-$svc.json)\",\"executionRoleArn\":\"arn:aws:iam::$ACCOUNT_ID:role/mytutorial-ecs-execution-role\",\"taskRoleArn\":\"arn:aws:iam::$ACCOUNT_ID:role/mytutorial-ecs-task-role\"}" --region "$AWS_REGION" > /dev/null
done

# ── Update services ────────────────────────────────────────────────────────
echo "=== Updating ECS services ==="
for svc in "${SERVICES[@]}"; do
  echo "--- $svc ---"
  LATEST_TD=$(aws ecs list-task-definitions --family-prefix "mytutorial-$svc" --sort DESC --max-items 1 --query 'taskDefinitionArns[0]' --output text)
  aws ecs update-service \
    --cluster "$CLUSTER" \
    --service "$svc" \
    --task-definition "$LATEST_TD" \
    --force-new-deployment \
    --region "$AWS_REGION" > /dev/null
done

# ── Wait for stability ─────────────────────────────────────────────────────
echo "=== Waiting for deployments to stabilize ==="
for svc in "${SERVICES[@]}"; do
  echo "--- $svc ---"
  aws ecs wait services-stable \
    --cluster "$CLUSTER" \
    --services "$svc" \
    --region "$AWS_REGION"
done

echo ""
echo "=== Deployment complete ==="
echo "Tag: $TAG"
echo "Cluster: $CLUSTER"