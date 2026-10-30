#!/usr/bin/env bash
# Step 5: log group, ECS cluster, Cloud Map namespace, load balancer, public DNS.
#   Cloud Map private DNS namespace paylab.internal (ECS Service Discovery)
#   ALB paylab-alb
#     HTTP  :80   -> redirect to HTTPS (301)
#     HTTPS :443  (ACM cert from 00-dns-cert.sh)
#        rule 10  host api.lab.aricxpoint.co -> paylab-tg     (api-gateway, 8080)
#        rule 20  path /api/*                -> paylab-tg     (same-origin calls from the web page)
#        default                             -> paylab-web-tg (web, 3000)
#   Route 53 alias A records pay.lab.aricxpoint.co and api.lab.aricxpoint.co -> ALB
# Safe to re-run.
set -euo pipefail
source "$(dirname "$0")/config.sh"

ALB_SG="$(sg_id alb-sg)"
found "$ALB_SG" || { echo "alb-sg not found - run 01-network.sh first" >&2; exit 1; }
ZONE_ID="$(zone_id)"
found "$ZONE_ID" || { echo "public hosted zone ${DOMAIN_ZONE} not found" >&2; exit 1; }
CERT_ARN="$(cert_arn)"
found "$CERT_ARN" || { echo "no ACM certificate for ${WEB_HOST} - run 00-dns-cert.sh first" >&2; exit 1; }
CERT_STATUS="$(aws acm describe-certificate --certificate-arn "$CERT_ARN" --query Certificate.Status --output text)"
[ "$CERT_STATUS" = "ISSUED" ] || { echo "certificate is ${CERT_STATUS}, not ISSUED - finish 00-dns-cert.sh first" >&2; exit 1; }

# ECS needs its service-linked role once per account ("already exists" is fine).
if aws iam create-service-linked-role --aws-service-name ecs.amazonaws.com >/dev/null 2>&1; then
  echo "created ECS service-linked role, waiting 15s for it to propagate ..."
  sleep 15
fi

# 1. Log group for all containers
if [ "$(aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" \
      --query "length(logGroups[?logGroupName=='${LOG_GROUP}'])" --output text)" = "0" ]; then
  aws logs create-log-group --log-group-name "$LOG_GROUP"
  echo "created log group ${LOG_GROUP}"
else
  echo "log group ${LOG_GROUP} exists"
fi
aws logs put-retention-policy --log-group-name "$LOG_GROUP" --retention-in-days 7

# 2. Cluster
STATUS="$(aws ecs describe-clusters --clusters "$CLUSTER" --query 'clusters[0].status' --output text 2>/dev/null || echo None)"
if [ "$STATUS" = "ACTIVE" ]; then
  echo "cluster ${CLUSTER} exists"
else
  retry aws ecs create-cluster --cluster-name "$CLUSTER" >/dev/null
  echo "created cluster ${CLUSTER}"
fi

# 3. Cloud Map private DNS namespace: services become <name>.paylab.internal inside the VPC.
NS_ID="$(namespace_id)"
if found "$NS_ID"; then
  echo "namespace ${NAMESPACE} exists (${NS_ID})"
else
  OP_ID="$(aws servicediscovery create-private-dns-namespace --name "$NAMESPACE" --vpc "$VPC_ID" \
    --description "PayLab service discovery" --query OperationId --output text)"
  echo "creating namespace ${NAMESPACE} (takes ~1 min) ..."
  wait_operation "$OP_ID"
  echo "created namespace ${NAMESPACE} ($(namespace_id))"
fi

# 4. Application Load Balancer in the default public subnets.
ALB_ARN="$(alb_arn)"
if found "$ALB_ARN"; then
  echo "load balancer ${ALB_NAME} exists"
else
  # shellcheck disable=SC2086  # $SUBNETS is a whitespace-separated list on purpose
  ALB_ARN="$(aws elbv2 create-load-balancer --name "$ALB_NAME" --type application --scheme internet-facing \
    --subnets $SUBNETS --security-groups "$ALB_SG" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
  echo "created load balancer ${ALB_NAME}"
fi

# 5. Target groups. Type "ip" because Fargate tasks get their own IP (awsvpc mode).
create_tg() {  # name port -> prints the ARN
  local arn
  arn="$(tg_arn "$1")"
  if found "$arn"; then
    echo "target group $1 exists" >&2
  else
    arn="$(aws elbv2 create-target-group --name "$1" \
      --protocol HTTP --port "$2" --vpc-id "$VPC_ID" --target-type ip \
      --health-check-path /health --health-check-interval-seconds 15 --healthy-threshold-count 2 \
      --query 'TargetGroups[0].TargetGroupArn' --output text)"
    echo "created target group $1 (port $2)" >&2
  fi
  echo "$arn"
}
API_TG_ARN="$(create_tg "$TG_NAME" 8080)"
WEB_TG_ARN="$(create_tg "$WEB_TG_NAME" 3000)"

echo "waiting for ${ALB_NAME} to become active ..."
aws elbv2 wait load-balancer-available --load-balancer-arns "$ALB_ARN"

listener_arn() {  # port
  aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
    --query "Listeners[?Port==\`$1\`].ListenerArn | [0]" --output text
}

# 6. HTTP :80 -> redirect everything to HTTPS.
REDIRECT='[{"Type":"redirect","RedirectConfig":{"Protocol":"HTTPS","Port":"443","StatusCode":"HTTP_301"}}]'
HTTP_ARN="$(listener_arn 80)"
if found "$HTTP_ARN"; then
  aws elbv2 modify-listener --listener-arn "$HTTP_ARN" --default-actions "$REDIRECT" >/dev/null
  # Remove any forwarding rules an older version of this script put on :80.
  for rule in $(aws elbv2 describe-rules --listener-arn "$HTTP_ARN" --query 'Rules[?IsDefault==`false`].RuleArn' --output text); do
    aws elbv2 delete-rule --rule-arn "$rule"
  done
  echo "listener :80 exists (redirect -> HTTPS)"
else
  aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" --protocol HTTP --port 80 \
    --default-actions "$REDIRECT" >/dev/null
  echo "created listener :80 (redirect -> HTTPS)"
fi

# 7. HTTPS :443, default -> web
SSL_POLICY=ELBSecurityPolicy-TLS13-1-2-2021-06
HTTPS_ARN="$(listener_arn 443)"
if found "$HTTPS_ARN"; then
  aws elbv2 modify-listener --listener-arn "$HTTPS_ARN" --protocol HTTPS --port 443 \
    --certificates "CertificateArn=${CERT_ARN}" --ssl-policy "$SSL_POLICY" \
    --default-actions "Type=forward,TargetGroupArn=${WEB_TG_ARN}" >/dev/null
  echo "listener :443 exists (default -> ${WEB_TG_NAME})"
else
  HTTPS_ARN="$(aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" --protocol HTTPS --port 443 \
    --certificates "CertificateArn=${CERT_ARN}" --ssl-policy "$SSL_POLICY" \
    --default-actions "Type=forward,TargetGroupArn=${WEB_TG_ARN}" \
    --query 'Listeners[0].ListenerArn' --output text)"
  echo "created listener :443 (default -> ${WEB_TG_NAME})"
fi

# 8. HTTPS rules -> api-gateway. Create, or update in place if the priority is taken.
ensure_rule() {  # priority conditions-json description
  local arn
  arn="$(aws elbv2 describe-rules --listener-arn "$HTTPS_ARN" \
    --query "Rules[?Priority=='$1'].RuleArn | [0]" --output text)"
  if found "$arn"; then
    aws elbv2 modify-rule --rule-arn "$arn" --conditions "$2" \
      --actions "Type=forward,TargetGroupArn=${API_TG_ARN}" >/dev/null
    echo "listener rule $1 exists: $3 -> ${TG_NAME}"
  else
    aws elbv2 create-rule --listener-arn "$HTTPS_ARN" --priority "$1" --conditions "$2" \
      --actions "Type=forward,TargetGroupArn=${API_TG_ARN}" >/dev/null
    echo "created listener rule $1: $3 -> ${TG_NAME}"
  fi
}
ensure_rule 10 "[{\"Field\":\"host-header\",\"HostHeaderConfig\":{\"Values\":[\"${API_HOST}\"]}}]" "host ${API_HOST}"
ensure_rule 20 '[{"Field":"path-pattern","PathPatternConfig":{"Values":["/api/*"]}}]' "path /api/*"

# 9. Public DNS: alias A records -> ALB
read -r ALB_DNS ALB_ZONE <<< "$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].[DNSName,CanonicalHostedZoneId]' --output text)"
alias_change() {  # host
  echo "{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"$1\",\"Type\":\"A\",\"AliasTarget\":{\"HostedZoneId\":\"${ALB_ZONE}\",\"DNSName\":\"${ALB_DNS}\",\"EvaluateTargetHealth\":false}}}"
}
CHANGE_ID="$(aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --change-batch "{\"Comment\":\"PayLab ALB aliases\",\"Changes\":[$(alias_change "$WEB_HOST"),$(alias_change "$API_HOST")]}" \
  --query ChangeInfo.Id --output text)"
aws route53 wait resource-record-sets-changed --id "$CHANGE_ID"
echo "DNS: ${WEB_HOST} and ${API_HOST} -> ${ALB_DNS}"

echo "Done. After 07-services.sh: https://${WEB_HOST}  and  https://${API_HOST}/health"
