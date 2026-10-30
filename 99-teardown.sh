#!/usr/bin/env bash
# Delete EVERYTHING PayLab created, so you stop paying. Safe to re-run.
set -euo pipefail
source "$(dirname "$0")/config.sh"

echo "This will PERMANENTLY delete all PayLab resources in profile=${AWS_PROFILE} region=${AWS_REGION}:"
echo "  pipelines, CodeBuild projects, artifact bucket ${ARTIFACT_BUCKET}, ECS services + cluster,"
echo "  ALB + target groups ${TG_NAME}/${WEB_TG_NAME}, RDS ${DB_INSTANCE} (NO snapshot),"
echo "  SSM parameters ${DB_PASSWORD_PARAM} ${DB_HOST_PARAM}, ECR repos paylab/*,"
echo "  Route 53 records ${WEB_HOST} + ${API_HOST} (only those two), log groups,"
echo "  Cloud Map namespace ${NAMESPACE} and its services, IAM roles, security groups."
echo "KEPT: hosted zone ${DOMAIN_ZONE} (and its NS/SOA), the ACM certificate and its validation records."
read -r -p "Type 'paylab' to continue: " answer
[ "$answer" = "paylab" ] || { echo "Aborted."; exit 1; }

# Run a command; if it fails (usually: already deleted) just say so and carry on.
try() { "$@" >/dev/null 2>&1 || echo "  (skipped: $*)"; }

echo "--> CodePipeline + CodeBuild"
for svc in "${SERVICES[@]}"; do
  try aws codepipeline delete-pipeline --name "paylab-${svc}-pipeline"
  try aws codebuild delete-project --name "paylab-${svc}-build"
done

echo "--> Artifact bucket (empty it, then delete)"
if aws s3api head-bucket --bucket "$ARTIFACT_BUCKET" >/dev/null 2>&1; then
  try aws s3 rm "s3://${ARTIFACT_BUCKET}" --recursive
  try aws s3api delete-bucket --bucket "$ARTIFACT_BUCKET"
fi

echo "--> ECS services + cluster"
for svc in "${SERVICES[@]}"; do
  try aws ecs delete-service --cluster "$CLUSTER" --service "$svc" --force
done
try aws ecs wait services-inactive --cluster "$CLUSTER" --services "${SERVICES[@]}"
try aws ecs delete-cluster --cluster "$CLUSTER"
for svc in "${SERVICES[@]}"; do
  for arn in $(aws ecs list-task-definitions --family-prefix "paylab-${svc}" --query 'taskDefinitionArns[]' --output text 2>/dev/null || true); do
    try aws ecs deregister-task-definition --task-definition "$arn"
  done
done

echo "--> Cloud Map services + namespace ${NAMESPACE}"
NS_ID="$(namespace_id 2>/dev/null || echo None)"
if found "$NS_ID"; then
  for sd in $(aws servicediscovery list-services --filters "Name=NAMESPACE_ID,Values=${NS_ID},Condition=EQ" --query 'Services[].Id' --output text); do
    # ECS normally deregisters its tasks; remove any leftovers so the service can be deleted.
    for inst in $(aws servicediscovery list-instances --service-id "$sd" --query 'Instances[].Id' --output text 2>/dev/null || true); do
      try aws servicediscovery deregister-instance --service-id "$sd" --instance-id "$inst"
    done
    for attempt in $(seq 1 12); do
      if aws servicediscovery delete-service --id "$sd" >/dev/null 2>&1; then echo "  deleted Cloud Map service ${sd}"; break; fi
      echo "  Cloud Map service ${sd} still has instances, retrying in 10s (${attempt}/12)"; sleep 10
    done
  done
  if OP_ID="$(aws servicediscovery delete-namespace --id "$NS_ID" --query OperationId --output text 2>/dev/null)"; then
    wait_operation "$OP_ID" && echo "  deleted namespace ${NAMESPACE}" || echo "  (namespace delete did not finish; check the Cloud Map console)"
  else
    echo "  (skipped: could not delete namespace ${NAMESPACE})"
  fi
fi

echo "--> Route 53: alias records ${WEB_HOST} + ${API_HOST} (the hosted zone itself is kept)"
ZONE_ID="$(zone_id 2>/dev/null || echo None)"
if found "$ZONE_ID"; then
  CHANGES=""
  for host in "$WEB_HOST" "$API_HOST"; do
    # A DELETE must repeat the record exactly, so read it first.
    read -r HZ DNS EVAL <<< "$(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
      --query "ResourceRecordSets[?Name=='${host}.' && Type=='A'] | [0].AliasTarget.[HostedZoneId,DNSName,EvaluateTargetHealth]" \
      --output text)"
    found "${HZ:-}" || { echo "  (no A record for ${host})"; continue; }
    CHANGES="${CHANGES:+${CHANGES},}{\"Action\":\"DELETE\",\"ResourceRecordSet\":{\"Name\":\"${host}.\",\"Type\":\"A\",\"AliasTarget\":{\"HostedZoneId\":\"${HZ}\",\"DNSName\":\"${DNS}\",\"EvaluateTargetHealth\":$(echo "$EVAL" | tr '[:upper:]' '[:lower:]')}}}"
  done
  if [ -n "$CHANGES" ]; then
    try aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
      --change-batch "{\"Comment\":\"PayLab teardown\",\"Changes\":[${CHANGES}]}"
    echo "  deleted alias records"
  fi
fi

echo "--> Load balancer: listeners :443 and :80 (with their rules), then the ALB, then target groups"
ALB_ARN="$(alb_arn)"
if found "$ALB_ARN"; then
  for l in $(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --query 'Listeners[].ListenerArn' --output text 2>/dev/null || true); do
    try aws elbv2 delete-listener --listener-arn "$l"
  done
  try aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN"
  try aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN"
fi
for tg in "$TG_NAME" "$WEB_TG_NAME"; do
  TG_ARN="$(tg_arn "$tg")"
  if found "$TG_ARN"; then try aws elbv2 delete-target-group --target-group-arn "$TG_ARN"; fi
done

echo "--> RDS ${DB_INSTANCE} (no final snapshot, a few minutes)"
try aws rds delete-db-instance --db-instance-identifier "$DB_INSTANCE" --skip-final-snapshot --delete-automated-backups
try aws rds wait db-instance-deleted --db-instance-identifier "$DB_INSTANCE"

echo "--> SSM parameters"
try aws ssm delete-parameter --name "$DB_PASSWORD_PARAM"
try aws ssm delete-parameter --name "$DB_HOST_PARAM"

echo "--> ECR repositories"
for svc in "${SERVICES[@]}"; do
  try aws ecr delete-repository --repository-name "paylab/${svc}" --force
done

echo "--> Log groups"
try aws logs delete-log-group --log-group-name "$LOG_GROUP"
for svc in "${SERVICES[@]}"; do
  try aws logs delete-log-group --log-group-name "/aws/codebuild/paylab-${svc}-build"
done


echo "--> IAM roles"
for role in "$PIPELINE_ROLE" "$CODEBUILD_ROLE" "$TASK_ROLE" "$EXEC_ROLE"; do
  aws iam get-role --role-name "$role" >/dev/null 2>&1 || continue
  for p in $(aws iam list-role-policies --role-name "$role" --query 'PolicyNames[]' --output text); do
    try aws iam delete-role-policy --role-name "$role" --policy-name "$p"
  done
  for p in $(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text); do
    try aws iam detach-role-policy --role-name "$role" --policy-arn "$p"
  done
  try aws iam delete-role --role-name "$role"
done

echo "--> Security groups (db-sg, app-sg, alb-sg)"
for name in db-sg app-sg alb-sg; do
  SG_ID="$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=${name}" "Name=tag:Project,Values=paylab" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
  found "$SG_ID" || continue
  # Network interfaces from tasks/ALB/RDS take a little while to disappear, so retry.
  for attempt in $(seq 1 20); do
    if aws ec2 delete-security-group --group-id "$SG_ID" >/dev/null 2>&1; then
      echo "  deleted ${name} (${SG_ID})"; break
    fi
    echo "  ${name} still in use, retrying in 15s (${attempt}/20)"; sleep 15
  done
done

echo "Teardown complete. Check the console (ECS, EC2 > Load Balancers, RDS, CodePipeline) to be sure."
echo "Kept on purpose: hosted zone ${DOMAIN_ZONE} (NS/SOA), the ACM certificate for ${WEB_HOST}/${API_HOST}"
echo "and its validation CNAMEs, so the next run of 05 can reuse them (00-dns-cert.sh is a no-op then)."
echo "The GitHub connection is free; delete it in the console if you no longer need it."
