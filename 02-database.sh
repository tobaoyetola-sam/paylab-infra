#!/usr/bin/env bash
# Step 2: DB password in SSM Parameter Store + RDS PostgreSQL "paylab-db".
#   /paylab/db/password  SecureString (encrypted with the AWS-managed key alias/aws/ssm)
#   /paylab/db/host      String (the RDS endpoint, written once RDS is available)
# Takes ~10 minutes. Run it BEFORE class. Safe to re-run.
set -euo pipefail
source "$(dirname "$0")/config.sh"

DB_SG="$(sg_id db-sg)"
found "$DB_SG" || { echo "db-sg not found - run 01-network.sh first" >&2; exit 1; }

# 1. The password. Re-use the stored one if it exists, so a re-run never
#    drifts away from the password RDS was created with.
if DB_PASSWORD="$(aws ssm get-parameter --name "$DB_PASSWORD_PARAM" --with-decryption \
      --query Parameter.Value --output text 2>/dev/null)"; then
  echo "parameter ${DB_PASSWORD_PARAM} exists, re-using it"
  NEW_PASSWORD=false
else
  NEW_PASSWORD=true
  # Hex = letters and digits only: safe for RDS (which rejects / @ " and space) and for URLs.
  DB_PASSWORD="$(openssl rand -hex 16)"
  aws ssm put-parameter --name "$DB_PASSWORD_PARAM" --type SecureString \
    --value "$DB_PASSWORD" --description "PayLab RDS master password" >/dev/null
  echo "created parameter ${DB_PASSWORD_PARAM} (SecureString, alias/aws/ssm)"
fi

# 2. The database (default VPC, not publicly accessible, only reachable through db-sg).
STATUS="$(aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE" \
  --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo None)"
case "$STATUS" in
  None)
    aws rds create-db-instance \
      --db-instance-identifier "$DB_INSTANCE" \
      --engine postgres --engine-version 16 \
      --db-instance-class db.t4g.micro \
      --allocated-storage 20 --storage-type gp3 \
      --db-name paylab \
      --master-username paylab \
      --master-user-password "$DB_PASSWORD" \
      --vpc-security-group-ids "$DB_SG" \
      --no-publicly-accessible \
      --no-multi-az \
      --backup-retention-period 0 >/dev/null
    echo "creating RDS ${DB_INSTANCE} ..."
    ;;
  deleting)
    echo "RDS ${DB_INSTANCE} is still being deleted (from a teardown). Wait for that to finish, then re-run." >&2
    exit 1
    ;;
  *)
    echo "RDS ${DB_INSTANCE} already exists (status: ${STATUS})"
    if [ "$NEW_PASSWORD" = true ]; then
      # The parameter was missing, so we just made a new password: set it on RDS too.
      aws rds wait db-instance-available --db-instance-identifier "$DB_INSTANCE"
      aws rds modify-db-instance --db-instance-identifier "$DB_INSTANCE" \
        --master-user-password "$DB_PASSWORD" --apply-immediately >/dev/null
      echo "reset the RDS master password to match ${DB_PASSWORD_PARAM}"
      sleep 30   # the modify takes a moment to start; the wait below then catches it
    fi
    ;;
esac

echo "waiting for ${DB_INSTANCE} to be available (~10 min; the waiter gives up after 30 min) ..."
aws rds wait db-instance-available --db-instance-identifier "$DB_INSTANCE"

DB_HOST="$(aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE" \
  --query 'DBInstances[0].Endpoint.Address' --output text)"
aws ssm put-parameter --name "$DB_HOST_PARAM" --type String --value "$DB_HOST" \
  --description "PayLab RDS endpoint" --overwrite >/dev/null
echo "Done: ${DB_INSTANCE} is available at ${DB_HOST} (saved to ${DB_HOST_PARAM})"
