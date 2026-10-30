# Shared settings for every script in this repo. Sourced, not run directly.
# shellcheck shell=bash

export AWS_PROFILE="${AWS_PROFILE:-aricxpoint-lab}"
export AWS_REGION="${AWS_REGION:-eu-west-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_PAGER=""   # don't open a pager for CLI output

# The five services (each is its own repo: paylab-<service>) and their ports.
SERVICES=(api-gateway payment-svc wallet-svc notify-svc web)
port_of() {
  case "$1" in
    api-gateway) echo 8080 ;;
    payment-svc) echo 8081 ;;
    wallet-svc)  echo 8082 ;;
    notify-svc)  echo 8083 ;;
    web)         echo 3000 ;;
  esac
}

# Fixed names (the slides use these).
CLUSTER=paylab
NAMESPACE=paylab.internal   # Cloud Map private DNS namespace (ECS Service Discovery)

# Public DNS + HTTPS. The hosted zone already exists (delegated from Cloudflare);
# these scripts never create or delete it.
DOMAIN_ZONE="${DOMAIN_ZONE:-lab.aricxpoint.co}"
WEB_HOST="${WEB_HOST:-pay.lab.aricxpoint.co}"
API_HOST="${API_HOST:-api.lab.aricxpoint.co}"
LOG_GROUP=/ecs/paylab
DB_PASSWORD_PARAM=/paylab/db/password   # SSM Parameter Store, SecureString
DB_HOST_PARAM=/paylab/db/host           # SSM Parameter Store, String
DB_INSTANCE=paylab-db
ALB_NAME=paylab-alb
TG_NAME=paylab-tg            # api-gateway (port 8080), gets /api/*
WEB_TG_NAME=paylab-web-tg    # web (port 3000), gets everything else
EXEC_ROLE=ecsTaskExecutionRole
TASK_ROLE=paylabTaskRole
CODEBUILD_ROLE=codebuild-paylab-role
PIPELINE_ROLE=codepipeline-paylab-role

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
# Safety guard: refuse to touch the wrong account. export EXPECTED_ACCOUNT_ID=<lab account id>
if [ -n "${EXPECTED_ACCOUNT_ID:-}" ] && [ "$EXPECTED_ACCOUNT_ID" != "$ACCOUNT_ID" ]; then
  echo "ERROR: profile '${AWS_PROFILE}' points at account ${ACCOUNT_ID}, but EXPECTED_ACCOUNT_ID is ${EXPECTED_ACCOUNT_ID}. Stopping." >&2
  exit 1
fi
ARTIFACT_BUCKET="paylab-artifacts-${ACCOUNT_ID}-${AWS_REGION}"

# Default VPC and its default (public) subnets.
VPC_ID="$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)"
if [ -z "$VPC_ID" ] || [ "$VPC_ID" = "None" ]; then
  echo "No default VPC in ${AWS_REGION}. Create one with: aws ec2 create-default-vpc" >&2
  exit 1
fi
SUBNETS="$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" Name=default-for-az,Values=true \
  --query 'Subnets[].SubnetId' --output text)"
SUBNETS_CSV="$(echo "$SUBNETS" | tr -s '[:space:]' ',' | sed 's/,$//')"

# --- small helpers -----------------------------------------------------------

# "None" or empty means "not found" in AWS CLI text output.
found() { [ -n "${1:-}" ] && [ "$1" != "None" ]; }

# Look up one of our security groups by name (prints "None" if it doesn't exist).
sg_id() {
  aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=$1" \
    --query 'SecurityGroups[0].GroupId' --output text
}

# Look up ARNs by name (print "None" if missing).
alb_arn() { aws elbv2 describe-load-balancers --names "$ALB_NAME" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || echo None; }
tg_arn()  { aws elbv2 describe-target-groups --names "$1" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || echo None; }

# Public hosted zone id for $DOMAIN_ZONE (e.g. Z0123...), "None" if missing.
zone_id() {
  local id
  id="$(aws route53 list-hosted-zones-by-name --dns-name "$DOMAIN_ZONE" \
    --query "HostedZones[?Name=='${DOMAIN_ZONE}.' && Config.PrivateZone==\`false\`].Id | [0]" --output text)"
  echo "${id#/hostedzone/}"
}

# ACM certificate for $WEB_HOST in this region (ISSUED or PENDING_VALIDATION), "None" if missing.
cert_arn() {
  aws acm list-certificates --certificate-statuses ISSUED PENDING_VALIDATION \
    --query "CertificateSummaryList[?DomainName=='${WEB_HOST}'].CertificateArn | [0]" --output text
}

# Cloud Map private DNS namespace id, "None" if missing.
namespace_id() {
  aws servicediscovery list-namespaces --filters Name=TYPE,Values=DNS_PRIVATE,Condition=EQ \
    --query "Namespaces[?Name=='${NAMESPACE}'].Id | [0]" --output text
}

# Wait for a Cloud Map operation (namespace create/delete) to finish.
wait_operation() {
  local status i
  for i in $(seq 1 60); do
    status="$(aws servicediscovery get-operation --operation-id "$1" --query Operation.Status --output text)"
    case "$status" in
      SUCCESS) return 0 ;;
      FAIL) echo "Cloud Map operation $1 failed:" >&2
            aws servicediscovery get-operation --operation-id "$1" --query Operation.ErrorMessage --output text >&2
            return 1 ;;
    esac
    sleep 5
  done
  echo "timed out waiting for Cloud Map operation $1" >&2
  return 1
}

# Retry a command a few times. Used right after creating IAM roles: a new role
# can take 10-30 seconds before CodeBuild/CodePipeline/ECS accept it.
retry() {
  local attempt
  for attempt in 1 2 3 4 5 6; do
    if "$@"; then return 0; fi
    echo "  ...failed (attempt ${attempt}/6), retrying in 10s" >&2
    sleep 10
  done
  "$@"
}

echo "== account=${ACCOUNT_ID} region=${AWS_REGION} profile=${AWS_PROFILE} vpc=${VPC_ID}"
