locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = var.region
  namespace  = "paylab.internal" # Cloud Map private DNS namespace

  # domain_zone = "" -> no Route 53 / certificate; the site is http://<ALB DNS name>
  use_domain = var.domain_zone != ""
  web_origin = local.use_domain ? "https://${var.web_host}" : "http://${aws_lb.paylab.dns_name}"

  # One entry per service (= one GitHub repo paylab-<name>, one ECR repo paylab/<name>,
  # one task definition paylab-<name>, one ECS service <name>, one pipeline).
  #   target_group: "api" / "web" = attached to that ALB target group, null = internal only
  #   cloud_map:    register tasks as <name>.paylab.internal
  #   needs_db:     gets DB_* env vars + DB_PASSWORD from SSM Parameter Store
  services = {
    "api-gateway" = {
      port         = 8080
      cpu          = 256
      memory       = 512
      health_path  = "/health"
      target_group = "api"
      cloud_map    = true
      needs_db     = false
      env = {
        WALLET_URL  = "http://wallet-svc.paylab.internal:8082"
        PAYMENT_URL = "http://payment-svc.paylab.internal:8081"
        CORS_ORIGIN = local.web_origin
      }
    }
    "payment-svc" = {
      port         = 8081
      cpu          = 256
      memory       = 512
      health_path  = "/health"
      target_group = null
      cloud_map    = true
      needs_db     = true
      env = {
        WALLET_URL = "http://wallet-svc.paylab.internal:8082"
        NOTIFY_URL = "http://notify-svc.paylab.internal:8083"
      }
    }
    "wallet-svc" = {
      port         = 8082
      cpu          = 256
      memory       = 512
      health_path  = "/health"
      target_group = null
      cloud_map    = true
      needs_db     = true
      env          = {}
    }
    "notify-svc" = {
      port         = 8083
      cpu          = 256
      memory       = 512
      health_path  = "/health"
      target_group = null
      cloud_map    = true
      needs_db     = false
      env          = {}
    }
    "web" = {
      port         = 3000
      cpu          = 256
      memory       = 512
      health_path  = "/health"
      target_group = "web"
      cloud_map    = false
      needs_db     = false
      env          = {} # API_BASE stays "" (same origin; the ALB sends /api/* to api-gateway)
    }
  }

  cloud_map_services = { for k, v in local.services : k => v if v.cloud_map }

  db_env = {
    DB_HOST = aws_db_instance.paylab.address
    DB_PORT = "5432"
    DB_NAME = "paylab"
    DB_USER = "paylab"
    DB_SSL  = "true"
  }

  artifact_bucket = "paylab-artifacts-${local.account_id}-${local.region}"
}
