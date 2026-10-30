#!/usr/bin/env bash
# Step 1: security groups in the default VPC.
#   alb-sg : ports 80 and 443 from the internet
#   app-sg : 8080 (api-gateway) and 3000 (web) from alb-sg,
#            plus all ports between app-sg members (service-to-service)
#   db-sg  : port 5432 from app-sg
# Safe to re-run: existing groups and rules are kept.
set -euo pipefail
source "$(dirname "$0")/config.sh"

create_sg() {  # name description -> prints the group id
  local id
  id="$(sg_id "$1")"
  if found "$id"; then
    echo "exists  $1 = $id" >&2
  else
    id="$(aws ec2 create-security-group --group-name "$1" --description "$2" --vpc-id "$VPC_ID" \
      --tag-specifications 'ResourceType=security-group,Tags=[{Key=Project,Value=paylab}]' \
      --query GroupId --output text)"
    echo "created $1 = $id" >&2
  fi
  echo "$id"
}

# Add an ingress rule. "Already exists" is fine; any other error stops the script.
allow() {
  local out
  if ! out="$(aws ec2 authorize-security-group-ingress "$@" 2>&1)"; then
    if echo "$out" | grep -q 'InvalidPermission.Duplicate'; then
      echo "  rule exists: $*" >&2
    else
      echo "$out" >&2
      return 1
    fi
  else
    echo "  rule added:  $*" >&2
  fi
}

ALB_SG="$(create_sg alb-sg "PayLab ALB")"
APP_SG="$(create_sg app-sg "PayLab ECS tasks")"
DB_SG="$(create_sg db-sg "PayLab RDS")"

allow --group-id "$ALB_SG" --protocol tcp --port 80   --cidr 0.0.0.0/0
allow --group-id "$ALB_SG" --protocol tcp --port 443  --cidr 0.0.0.0/0
allow --group-id "$APP_SG" --protocol tcp --port 8080 --source-group "$ALB_SG"
allow --group-id "$APP_SG" --protocol tcp --port 3000 --source-group "$ALB_SG"
allow --group-id "$APP_SG" --protocol -1              --source-group "$APP_SG"
allow --group-id "$DB_SG"  --protocol tcp --port 5432 --source-group "$APP_SG"

echo "Done: alb-sg=${ALB_SG} app-sg=${APP_SG} db-sg=${DB_SG}"
