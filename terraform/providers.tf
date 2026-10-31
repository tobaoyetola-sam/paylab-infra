# Credentials come from the environment (AWS_PROFILE / SSO login), never from this file.
provider "aws" {
  region = var.region

  # Refuse to touch any account except the lab account.
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = {
      Project   = "paylab"
      ManagedBy = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}
