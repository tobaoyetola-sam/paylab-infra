# S3 bucket where CodePipeline passes artifacts between stages.
resource "aws_s3_bucket" "artifacts" {
  bucket        = local.artifact_bucket
  force_destroy = true # terraform destroy empties it first
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# Build logs (created here so terraform destroy removes them too).
resource "aws_cloudwatch_log_group" "codebuild" {
  for_each = local.services

  name              = "/aws/codebuild/paylab-${each.key}-build"
  retention_in_days = 7
}

# One CodeBuild project per service: runs the repo's buildspec.yml
# (docker build, push :<sha> and :latest, write imagedefinitions.json).
resource "aws_codebuild_project" "svc" {
  for_each = local.services

  name         = "paylab-${each.key}-build"
  description  = "Build and push paylab/${each.key}"
  service_role = aws_iam_role.codebuild.arn

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec.yml"
  }

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    type            = "LINUX_CONTAINER"
    image           = "aws/codebuild/standard:7.0"
    compute_type    = "BUILD_GENERAL1_SMALL"
    privileged_mode = true # required for docker build

    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = local.account_id
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.codebuild[each.key].name
    }
  }

  depends_on = [aws_iam_role_policy.codebuild]
}

# One CodePipeline (V2) per service: Source (GitHub) -> Build -> Deploy (ECS).
# A new pipeline starts its first run automatically, which builds and deploys
# the first image. After that every push to main triggers it.
resource "aws_codepipeline" "svc" {
  for_each = local.services

  name          = "paylab-${each.key}-pipeline"
  pipeline_type = "V2"
  role_arn      = aws_iam_role.codepipeline.arn

  artifact_store {
    type     = "S3"
    location = aws_s3_bucket.artifacts.bucket
  }

  stage {
    name = "Source"
    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["SourceOutput"]
      configuration = {
        ConnectionArn        = var.connection_arn
        FullRepositoryId     = "${var.github_owner}/paylab-${each.key}"
        BranchName           = var.github_branch
        OutputArtifactFormat = "CODE_ZIP"
        DetectChanges        = "true"
      }
    }
  }

  stage {
    name = "Build"
    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["SourceOutput"]
      output_artifacts = ["BuildOutput"]
      configuration = {
        ProjectName = aws_codebuild_project.svc[each.key].name
      }
    }
  }

  stage {
    name = "Deploy"
    action {
      name            = "Deploy"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "ECS"
      version         = "1"
      input_artifacts = ["BuildOutput"]
      configuration = {
        ClusterName = aws_ecs_cluster.paylab.name
        ServiceName = aws_ecs_service.svc[each.key].name
        FileName    = "imagedefinitions.json"
      }
    }
  }

  trigger {
    provider_type = "CodeStarSourceConnection"
    git_configuration {
      source_action_name = "Source"
      push {
        branches {
          includes = [var.github_branch]
        }
      }
    }
  }

  depends_on = [aws_iam_role_policy.codepipeline]
}
