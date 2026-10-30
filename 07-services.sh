#!/usr/bin/env bash
# Step 7: register each repo's taskdef.json and create the 5 ECS services.
# Service discovery: each backend service registers its tasks' private IPs in Cloud Map,
# which publishes them as Route 53 private DNS A records:
#   wallet-svc.paylab.internal, payment-svc.paylab.internal, notify-svc.paylab.internal, api-gateway.paylab.internal
# The task definitions point WALLET_URL etc. at those names.
#   api-gateway -> target group paylab-tg     (ALB: host api.lab..., path /api/*)
#   web         -> target group paylab-web-tg (ALB default)
#
# Usage: ./07-services.sh <dir-containing-the-service-repos>      e.g. ./07-services.sh ..
# Safe to re-run: registers a new task definition revision each time, but leaves
# existing services alone (CodePipeline takes care of updates after this).
set -euo pipefail
source "$(dirname "$0")/config.sh"

REPOS_DIR="${1:?usage: $0 <dir containing paylab-api-gateway, paylab-payment-svc, ..., paylab-web>}"

APP_SG="$(sg_id app-sg)"
found "$APP_SG" || { echo "app-sg not found - run 01-network.sh first" >&2; exit 1; }
DB_HOST="$(aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE" \
  --query 'DBInstances[0].Endpoint.Address' --output text 2>/dev/null || echo None)"
found "$DB_HOST" || { echo "RDS ${DB_INSTANCE} has no endpoint yet - run/finish 02-database.sh" >&2; exit 1; }
API_TG_ARN="$(tg_arn "$TG_NAME")"
WEB_TG_ARN="$(tg_arn "$WEB_TG_NAME")"
found "$API_TG_ARN" && found "$WEB_TG_ARN" || { echo "target groups not found - run 05-ecs.sh first" >&2; exit 1; }
NS_ID="$(namespace_id)"
found "$NS_ID" || { echo "Cloud Map namespace ${NAMESPACE} not found - run 05-ecs.sh first" >&2; exit 1; }

NETWORK="awsvpcConfiguration={subnets=[${SUBNETS_CSV}],securityGroups=[${APP_SG}],assignPublicIp=ENABLED}"
RENDERED="$(dirname "$0")/rendered"
mkdir -p "$RENDERED"

# 1. Fill in the placeholders and register the task definitions.
for svc in "${SERVICES[@]}"; do
  sed -e "s|<ACCOUNT_ID>|${ACCOUNT_ID}|g" \
      -e "s|<REGION>|${AWS_REGION}|g" \
      -e "s|<DB_HOST>|${DB_HOST}|g" \
      -e "s|<WEB_HOST>|${WEB_HOST}|g" \
      "${REPOS_DIR}/paylab-${svc}/taskdef.json" > "${RENDERED}/${svc}.json"
  if grep -q '<[A-Z_]*>' "${RENDERED}/${svc}.json"; then
    echo "unfilled placeholder in ${RENDERED}/${svc}.json" >&2; exit 1
  fi
  aws ecs register-task-definition --cli-input-json "file://${RENDERED}/${svc}.json" \
    --query 'taskDefinition.taskDefinitionArn' --output text
done

# 2. Cloud Map service per backend (A record, TTL 10s, one record per healthy task).
registry_arn() {  # name -> ARN of the Cloud Map service, created if missing
  local arn
  arn="$(aws servicediscovery list-services --filters "Name=NAMESPACE_ID,Values=${NS_ID},Condition=EQ" \
    --query "Services[?Name=='$1'].Arn | [0]" --output text)"
  if found "$arn"; then
    echo "Cloud Map service $1 exists" >&2
  else
    arn="$(aws servicediscovery create-service --name "$1" --namespace-id "$NS_ID" \
      --dns-config '{"RoutingPolicy":"MULTIVALUE","DnsRecords":[{"Type":"A","TTL":10}]}' \
      --health-check-custom-config FailureThreshold=1 \
      --query Service.Arn --output text)"
    echo "created Cloud Map service $1 (${1}.${NAMESPACE})" >&2
  fi
  echo "$arn"
}

# 3. Create the ECS services: callees first, then callers, then the frontend.
for svc in notify-svc wallet-svc payment-svc api-gateway web; do
  status="$(aws ecs describe-services --cluster "$CLUSTER" --services "$svc" \
    --query 'services[0].status' --output text 2>/dev/null || echo None)"
  if [ "$status" = "ACTIVE" ]; then
    echo "service ${svc} exists"
    continue
  fi
  if [ "$status" = "DRAINING" ]; then
    echo "service ${svc} is still being deleted, waiting ..."
    aws ecs wait services-inactive --cluster "$CLUSTER" --services "$svc"
  fi

  sd=()
  if [ "$svc" != "web" ]; then
    registry="$(registry_arn "$svc")"
    sd=(--service-registries "registryArn=${registry}")
  fi
  lb=()
  case "$svc" in
    api-gateway) lb=(--load-balancers "targetGroupArn=${API_TG_ARN},containerName=api-gateway,containerPort=8080"
                     --health-check-grace-period-seconds 60) ;;
    web)         lb=(--load-balancers "targetGroupArn=${WEB_TG_ARN},containerName=web,containerPort=3000"
                     --health-check-grace-period-seconds 30) ;;
  esac

  aws ecs create-service --cluster "$CLUSTER" --service-name "$svc" \
    --task-definition "paylab-${svc}" --desired-count 1 --launch-type FARGATE \
    --network-configuration "$NETWORK" \
    ${sd[@]+"${sd[@]}"} ${lb[@]+"${lb[@]}"} >/dev/null
  echo "created service ${svc}"
done

echo "waiting for all services to become stable (usually 2-5 min; the waiter gives up after 10 min) ..."
if ! aws ecs wait services-stable --cluster "$CLUSTER" --services "${SERVICES[@]}"; then
  echo "Not stable yet. Check: aws ecs describe-services --cluster ${CLUSTER} --services <svc> --query 'services[0].events[:5]'" >&2
  echo "and: aws logs tail ${LOG_GROUP} --since 15m" >&2
  exit 1
fi
aws ecs describe-services --cluster "$CLUSTER" --services "${SERVICES[@]}" \
  --query 'services[].[serviceName,status,runningCount,desiredCount]' --output table
echo "Open: https://${WEB_HOST}   API: https://${API_HOST}/health"
