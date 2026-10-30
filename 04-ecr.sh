#!/usr/bin/env bash
# Step 4: one ECR repository per service: paylab/<service>  (incl. paylab/web)
# Safe to re-run.
set -euo pipefail
source "$(dirname "$0")/config.sh"

for svc in "${SERVICES[@]}"; do
  if aws ecr describe-repositories --repository-names "paylab/${svc}" >/dev/null 2>&1; then
    echo "exists  paylab/${svc}"
  else
    aws ecr create-repository --repository-name "paylab/${svc}" \
      --image-scanning-configuration scanOnPush=true >/dev/null
    echo "created paylab/${svc}"
  fi
done
