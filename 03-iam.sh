#!/usr/bin/env bash
# Step 3: IAM roles.
#   ecsTaskExecutionRole     - ECS uses it to pull images, write logs and read /paylab/db/password from SSM
#   paylabTaskRole           - the role our app code runs as (needs no permissions)
#   codebuild-paylab-role    - CodeBuild: push to ECR, write build logs, read/write pipeline artifacts
#   codepipeline-paylab-role - CodePipeline: artifacts, start CodeBuild, deploy to ECS, use the GitHub connection
# Safe to re-run: policies are simply overwritten.
set -euo pipefail
source "$(dirname "$0")/config.sh"

PARAM_ARN="arn:aws:ssm:${AWS_REGION}:${ACCOUNT_ID}:parameter${DB_PASSWORD_PARAM}"
ECR_ARN="arn:aws:ecr:${AWS_REGION}:${ACCOUNT_ID}:repository/paylab/*"
CREATED_ANY=false

trust() {  # service principal -> trust policy JSON
  echo "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"$1\"},\"Action\":\"sts:AssumeRole\"}]}"
}

create_role() {  # name principal
  if aws iam get-role --role-name "$1" >/dev/null 2>&1; then
    echo "role $1 exists"
  else
    aws iam create-role --role-name "$1" --assume-role-policy-document "$(trust "$2")" >/dev/null
    echo "created role $1"
    CREATED_ANY=true
  fi
}

# --- ECS task execution role ---
create_role "$EXEC_ROLE" ecs-tasks.amazonaws.com
aws iam attach-role-policy --role-name "$EXEC_ROLE" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
# Read ONLY the DB password parameter. kms:Decrypt is for the SecureString's key
# (AWS-managed alias/aws/ssm), and only when the call comes through SSM.
aws iam put-role-policy --role-name "$EXEC_ROLE" --policy-name paylab-read-db-password --policy-document "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [
    {\"Effect\": \"Allow\", \"Action\": \"ssm:GetParameters\", \"Resource\": \"${PARAM_ARN}\"},
    {\"Effect\": \"Allow\", \"Action\": \"kms:Decrypt\", \"Resource\": \"arn:aws:kms:${AWS_REGION}:${ACCOUNT_ID}:key/*\",
     \"Condition\": {\"StringEquals\": {\"kms:ViaService\": \"ssm.${AWS_REGION}.amazonaws.com\"}}}
  ]
}"

# --- ECS task role (empty) ---
create_role "$TASK_ROLE" ecs-tasks.amazonaws.com

# --- CodeBuild role ---
create_role "$CODEBUILD_ROLE" codebuild.amazonaws.com
aws iam put-role-policy --role-name "$CODEBUILD_ROLE" --policy-name paylab-codebuild --policy-document "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [
    {\"Effect\": \"Allow\", \"Action\": \"ecr:GetAuthorizationToken\", \"Resource\": \"*\"},
    {\"Effect\": \"Allow\", \"Action\": [
        \"ecr:BatchCheckLayerAvailability\", \"ecr:BatchGetImage\", \"ecr:GetDownloadUrlForLayer\",
        \"ecr:InitiateLayerUpload\", \"ecr:UploadLayerPart\", \"ecr:CompleteLayerUpload\", \"ecr:PutImage\"],
     \"Resource\": \"${ECR_ARN}\"},
    {\"Effect\": \"Allow\", \"Action\": [\"logs:CreateLogGroup\", \"logs:CreateLogStream\", \"logs:PutLogEvents\"],
     \"Resource\": \"arn:aws:logs:${AWS_REGION}:${ACCOUNT_ID}:log-group:/aws/codebuild/paylab-*\"},
    {\"Effect\": \"Allow\", \"Action\": [\"s3:GetObject\", \"s3:GetObjectVersion\", \"s3:PutObject\"],
     \"Resource\": \"arn:aws:s3:::${ARTIFACT_BUCKET}/*\"},
    {\"Effect\": \"Allow\", \"Action\": [\"s3:GetBucketAcl\", \"s3:GetBucketLocation\"],
     \"Resource\": \"arn:aws:s3:::${ARTIFACT_BUCKET}\"}
  ]
}"

# --- CodePipeline role ---
create_role "$PIPELINE_ROLE" codepipeline.amazonaws.com
aws iam put-role-policy --role-name "$PIPELINE_ROLE" --policy-name paylab-codepipeline --policy-document "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [
    {\"Effect\": \"Allow\", \"Action\": [\"s3:GetObject\", \"s3:GetObjectVersion\", \"s3:PutObject\",
        \"s3:GetBucketVersioning\", \"s3:GetBucketAcl\", \"s3:GetBucketLocation\"],
     \"Resource\": [\"arn:aws:s3:::${ARTIFACT_BUCKET}\", \"arn:aws:s3:::${ARTIFACT_BUCKET}/*\"]},
    {\"Effect\": \"Allow\", \"Action\": [\"codebuild:StartBuild\", \"codebuild:BatchGetBuilds\"],
     \"Resource\": \"arn:aws:codebuild:${AWS_REGION}:${ACCOUNT_ID}:project/paylab-*\"},
    {\"Effect\": \"Allow\", \"Action\": [
        \"ecs:DescribeServices\", \"ecs:DescribeTaskDefinition\", \"ecs:DescribeTasks\", \"ecs:ListTasks\",
        \"ecs:RegisterTaskDefinition\", \"ecs:UpdateService\", \"ecs:TagResource\"],
     \"Resource\": \"*\"},
    {\"Effect\": \"Allow\", \"Action\": \"iam:PassRole\",
     \"Resource\": [\"arn:aws:iam::${ACCOUNT_ID}:role/${EXEC_ROLE}\", \"arn:aws:iam::${ACCOUNT_ID}:role/${TASK_ROLE}\"],
     \"Condition\": {\"StringEquals\": {\"iam:PassedToService\": \"ecs-tasks.amazonaws.com\"}}},
    {\"Effect\": \"Allow\", \"Action\": [\"codestar-connections:UseConnection\", \"codeconnections:UseConnection\"],
     \"Resource\": \"*\"}
  ]
}"

# New IAM roles take a little while to be usable by other AWS services.
if [ "$CREATED_ANY" = true ]; then
  echo "waiting 20s for new IAM roles to propagate ..."
  sleep 20
fi
echo "Done."
