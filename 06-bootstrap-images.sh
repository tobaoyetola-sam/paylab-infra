#!/usr/bin/env bash
# Step 6 (one time only): build and push paylab/<service>:v1 from your laptop,
# so the ECS services in step 7 have an image to start with.
# After this, every push to GitHub is built and deployed by CodePipeline.
#
# Usage: ./06-bootstrap-images.sh <dir-containing-the-service-repos>
#   e.g. ./06-bootstrap-images.sh ..   (expects ../paylab-api-gateway, ../paylab-web, ...)
# Safe to re-run (it just rebuilds and pushes :v1 again).
set -euo pipefail
source "$(dirname "$0")/config.sh"

REPOS_DIR="${1:?usage: $0 <dir containing paylab-api-gateway, paylab-payment-svc, ..., paylab-web>}"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

for svc in "${SERVICES[@]}"; do
  [ -f "${REPOS_DIR}/paylab-${svc}/Dockerfile" ] || { echo "no Dockerfile in ${REPOS_DIR}/paylab-${svc}" >&2; exit 1; }
done

aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY"

for svc in "${SERVICES[@]}"; do
  image="${REGISTRY}/paylab/${svc}:v1"
  echo "==> ${image}"
  # Fargate runs X86_64; this matters on Apple Silicon Macs.
  docker build --platform linux/amd64 -t "$image" "${REPOS_DIR}/paylab-${svc}"

  # Safety check: on a flaky network "npm ci" can fail but still exit 0, which
  # gives an image without dependencies. Catch that here instead of in ECS.
  if [ "$svc" != "web" ]; then
    docker run --rm --platform linux/amd64 --entrypoint node "$image" -e "require('express')" \
      || { echo "image ${image} is missing node_modules - npm ci failed during the build" >&2; exit 1; }
  fi

  docker push "$image"
done
echo "Done. Pushed :v1 for ${SERVICES[*]}"
