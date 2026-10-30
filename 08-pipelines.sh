#!/usr/bin/env bash
# Step 8: CI/CD. For each service:
#   CodeBuild project  paylab-<svc>-build     (svc = api-gateway, payment-svc, wallet-svc, notify-svc, web)
#       (runs the repo's buildspec.yml)
#   CodePipeline (V2)  paylab-<svc>-pipeline  Source (GitHub) -> Build -> Deploy (ECS)
# A push to "main" in GitHub repo $GITHUB_OWNER/paylab-<svc> triggers its pipeline.
#
# Required env vars:
#   CONNECTION_ARN  ARN of the GitHub connection (Developer Tools > Settings > Connections).
#                   It must be created in the CONSOLE and show status "Available" (see README).
#   GITHUB_OWNER    GitHub user or org that owns the paylab-* repos.
# Usage: CONNECTION_ARN=arn:aws:codeconnections:... GITHUB_OWNER=myname ./08-pipelines.sh
set -euo pipefail
: "${CONNECTION_ARN:?set CONNECTION_ARN (see README: create the GitHub connection in the console first)}"
: "${GITHUB_OWNER:?set GITHUB_OWNER (your GitHub user or org)}"
source "$(dirname "$0")/config.sh"

CODEBUILD_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${CODEBUILD_ROLE}"
PIPELINE_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${PIPELINE_ROLE}"

# 1. S3 bucket where CodePipeline passes artifacts between stages.
if aws s3api head-bucket --bucket "$ARTIFACT_BUCKET" >/dev/null 2>&1; then
  echo "bucket ${ARTIFACT_BUCKET} exists"
else
  if [ "$AWS_REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$ARTIFACT_BUCKET" >/dev/null
  else
    aws s3api create-bucket --bucket "$ARTIFACT_BUCKET" \
      --create-bucket-configuration "LocationConstraint=${AWS_REGION}" >/dev/null
  fi
  aws s3api put-public-access-block --bucket "$ARTIFACT_BUCKET" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  echo "created bucket ${ARTIFACT_BUCKET}"
fi

for svc in "${SERVICES[@]}"; do
  project="paylab-${svc}-build"
  pipeline="paylab-${svc}-pipeline"

  # 2. CodeBuild project. privilegedMode=true is required to run "docker build".
  if [ "$(aws codebuild batch-get-projects --names "$project" --query 'length(projects)' --output text)" = "0" ]; then
    retry aws codebuild create-project --cli-input-json "{
      \"name\": \"${project}\",
      \"description\": \"Build and push paylab/${svc}\",
      \"source\": {\"type\": \"CODEPIPELINE\", \"buildspec\": \"buildspec.yml\"},
      \"artifacts\": {\"type\": \"CODEPIPELINE\"},
      \"environment\": {
        \"type\": \"LINUX_CONTAINER\",
        \"image\": \"aws/codebuild/standard:7.0\",
        \"computeType\": \"BUILD_GENERAL1_SMALL\",
        \"privilegedMode\": true,
        \"environmentVariables\": [{\"name\": \"AWS_ACCOUNT_ID\", \"value\": \"${ACCOUNT_ID}\", \"type\": \"PLAINTEXT\"}]
      },
      \"serviceRole\": \"${CODEBUILD_ROLE_ARN}\",
      \"logsConfig\": {\"cloudWatchLogs\": {\"status\": \"ENABLED\", \"groupName\": \"/aws/codebuild/${project}\"}}
    }" >/dev/null
    echo "created CodeBuild project ${project}"
  else
    echo "CodeBuild project ${project} exists"
  fi

  # 3. CodePipeline V2: Source -> Build -> Deploy, triggered by pushes to main.
  definition="{
    \"pipeline\": {
      \"name\": \"${pipeline}\",
      \"pipelineType\": \"V2\",
      \"roleArn\": \"${PIPELINE_ROLE_ARN}\",
      \"artifactStore\": {\"type\": \"S3\", \"location\": \"${ARTIFACT_BUCKET}\"},
      \"stages\": [
        {\"name\": \"Source\", \"actions\": [{
          \"name\": \"Source\",
          \"actionTypeId\": {\"category\": \"Source\", \"owner\": \"AWS\", \"provider\": \"CodeStarSourceConnection\", \"version\": \"1\"},
          \"configuration\": {
            \"ConnectionArn\": \"${CONNECTION_ARN}\",
            \"FullRepositoryId\": \"${GITHUB_OWNER}/paylab-${svc}\",
            \"BranchName\": \"main\",
            \"OutputArtifactFormat\": \"CODE_ZIP\",
            \"DetectChanges\": \"true\"
          },
          \"outputArtifacts\": [{\"name\": \"SourceOutput\"}]
        }]},
        {\"name\": \"Build\", \"actions\": [{
          \"name\": \"Build\",
          \"actionTypeId\": {\"category\": \"Build\", \"owner\": \"AWS\", \"provider\": \"CodeBuild\", \"version\": \"1\"},
          \"configuration\": {\"ProjectName\": \"${project}\"},
          \"inputArtifacts\": [{\"name\": \"SourceOutput\"}],
          \"outputArtifacts\": [{\"name\": \"BuildOutput\"}]
        }]},
        {\"name\": \"Deploy\", \"actions\": [{
          \"name\": \"Deploy\",
          \"actionTypeId\": {\"category\": \"Deploy\", \"owner\": \"AWS\", \"provider\": \"ECS\", \"version\": \"1\"},
          \"configuration\": {\"ClusterName\": \"${CLUSTER}\", \"ServiceName\": \"${svc}\", \"FileName\": \"imagedefinitions.json\"},
          \"inputArtifacts\": [{\"name\": \"BuildOutput\"}]
        }]}
      ],
      \"triggers\": [{
        \"providerType\": \"CodeStarSourceConnection\",
        \"gitConfiguration\": {
          \"sourceActionName\": \"Source\",
          \"push\": [{\"branches\": {\"includes\": [\"main\"]}}]
        }
      }]
    }
  }"
  if aws codepipeline get-pipeline --name "$pipeline" >/dev/null 2>&1; then
    aws codepipeline update-pipeline --cli-input-json "$definition" >/dev/null
    echo "updated pipeline ${pipeline}"
  else
    retry aws codepipeline create-pipeline --cli-input-json "$definition" >/dev/null
    echo "created pipeline ${pipeline} (it starts a first run right away)"
  fi
done

echo "Done. Watch: aws codepipeline get-pipeline-state --name paylab-wallet-svc-pipeline --query 'stageStates[].[stageName,latestExecution.status]' --output table"
