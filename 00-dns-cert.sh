#!/usr/bin/env bash
# Step 0 (one time, persistent): HTTPS certificate for the lab domains.
#   ACM certificate for $WEB_HOST (pay.lab.aricxpoint.co) + SAN $API_HOST (api.lab.aricxpoint.co),
#   validated by DNS records in the EXISTING public hosted zone $DOMAIN_ZONE.
# Prerequisite: $DOMAIN_ZONE is delegated from Cloudflare (see README), or validation never finishes.
# The teardown script leaves the certificate and its validation records in place. Safe to re-run.
set -euo pipefail
source "$(dirname "$0")/config.sh"

ZONE_ID="$(zone_id)"
found "$ZONE_ID" || { echo "public hosted zone ${DOMAIN_ZONE} not found in this account" >&2; exit 1; }
echo "hosted zone ${DOMAIN_ZONE} = ${ZONE_ID}"

# 1. Reuse an ISSUED / PENDING_VALIDATION certificate for $WEB_HOST, or request one.
CERT_ARN="$(cert_arn)"
if found "$CERT_ARN"; then
  echo "reusing certificate ${CERT_ARN}"
else
  CERT_ARN="$(aws acm request-certificate \
    --domain-name "$WEB_HOST" \
    --subject-alternative-names "$API_HOST" \
    --validation-method DNS \
    --idempotency-token paylab \
    --query CertificateArn --output text)"
  echo "requested certificate ${CERT_ARN}"
fi

STATUS="$(aws acm describe-certificate --certificate-arn "$CERT_ARN" --query Certificate.Status --output text)"
if [ "$STATUS" = "ISSUED" ]; then
  echo "certificate is ISSUED. Nothing to do."
  exit 0
fi

# 2. ACM needs a few seconds before it publishes the validation records.
RECORDS=""
for attempt in $(seq 1 20); do
  RECORDS="$(aws acm describe-certificate --certificate-arn "$CERT_ARN" \
    --query 'Certificate.DomainValidationOptions[].ResourceRecord.[Name,Type,Value]' --output text)"
  # one line per domain, 3 fields each, none "None"
  if [ "$(echo "$RECORDS" | grep -c .)" -ge 2 ] && ! echo "$RECORDS" | grep -q None; then break; fi
  echo "  waiting for ACM validation records (${attempt}/20) ..."
  sleep 5
done

# 3. UPSERT the validation CNAMEs (deduplicated) into the hosted zone.
CHANGES=""
while read -r name type value; do
  [ -n "$name" ] || continue
  CHANGES="${CHANGES:+${CHANGES},}{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"${name}\",\"Type\":\"${type}\",\"TTL\":300,\"ResourceRecords\":[{\"Value\":\"${value}\"}]}}"
  echo "  validation record: ${name} ${type} ${value}"
done < <(echo "$RECORDS" | sort -u)
[ -n "$CHANGES" ] || { echo "ACM did not return validation records yet - re-run this script in a minute" >&2; exit 1; }

CHANGE_ID="$(aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --change-batch "{\"Comment\":\"PayLab ACM validation\",\"Changes\":[${CHANGES}]}" \
  --query ChangeInfo.Id --output text)"
aws route53 wait resource-record-sets-changed --id "$CHANGE_ID"
echo "validation records are in Route 53"

# 4. Wait for ACM (usually 1-5 minutes once the Cloudflare delegation works; the waiter gives up after 40 min).
echo "waiting for the certificate to be ISSUED ..."
aws acm wait certificate-validated --certificate-arn "$CERT_ARN"
echo "Done: ${CERT_ARN} is ISSUED for ${WEB_HOST}, ${API_HOST}"
