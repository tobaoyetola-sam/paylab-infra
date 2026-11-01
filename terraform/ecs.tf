resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/paylab"
  retention_in_days = 7
}

resource "aws_ecs_cluster" "paylab" {
  name = "paylab"
}

# ---------------------------------------------------------------------------
# Service discovery: Cloud Map private DNS namespace paylab.internal (a Route 53
# private zone on the default VPC). ECS registers each task's IP as an A record,
# e.g. wallet-svc.paylab.internal.
# ---------------------------------------------------------------------------
resource "aws_service_discovery_private_dns_namespace" "paylab" {
  name        = local.namespace
  description = "PayLab service discovery"
  vpc         = data.aws_vpc.default.id
}

resource "aws_service_discovery_service" "svc" {
  for_each = local.cloud_map_services

  name          = each.key
  force_destroy = true # deregister leftover instances on destroy

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.paylab.id
    routing_policy = "MULTIVALUE"
    dns_records {
      type = "A"
      ttl  = 10
    }
  }

  # ECS reports task health to Cloud Map (failure threshold is always 1 now; the
  # argument is deprecated, so the block is left empty).
  health_check_custom_config {}

  # AWS reads the empty block back as absent, which would make every plan
  # replace these services (and break discovery for a moment). Set it once.
  lifecycle {
    ignore_changes = [health_check_custom_config]
  }
}

# ---------------------------------------------------------------------------
# Task definitions (one per service)
# ---------------------------------------------------------------------------
resource "aws_ecs_task_definition" "svc" {
  for_each = local.services

  family                   = "paylab-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = each.value.cpu
  memory                   = each.value.memory
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  runtime_platform {
    cpu_architecture        = "X86_64"
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([{
    name      = each.key # MUST match "name" in the repo's imagedefinitions.json
    image     = "${aws_ecr_repository.svc[each.key].repository_url}:${var.bootstrap_image_tag}"
    essential = true

    portMappings = [{ containerPort = each.value.port, protocol = "tcp" }]

    environment = [
      for k, v in merge(
        { PORT = tostring(each.value.port) },
        each.value.needs_db ? local.db_env : {},
        each.value.env,
      ) : { name = k, value = v }
    ]

    secrets = each.value.needs_db ? [
      { name = "DB_PASSWORD", valueFrom = aws_ssm_parameter.db_password.arn }
    ] : []

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.ecs.name
        awslogs-region        = local.region
        awslogs-stream-prefix = each.key
      }
    }
  }])
}

# ---------------------------------------------------------------------------
# ECS services. On a fresh apply ECR is empty, so tasks fail to pull until each
# pipeline's first run pushes :latest and deploys. That's expected and self-heals.
# ---------------------------------------------------------------------------
resource "aws_ecs_service" "svc" {
  for_each = local.services

  name            = each.key
  cluster         = aws_ecs_cluster.paylab.id
  task_definition = aws_ecs_task_definition.svc[each.key].arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = true # needed to reach ECR/SSM without a NAT gateway
  }

  dynamic "load_balancer" {
    for_each = each.value.target_group == null ? [] : [each.value.target_group]
    content {
      target_group_arn = load_balancer.value == "api" ? aws_lb_target_group.api.arn : aws_lb_target_group.web.arn
      container_name   = each.key
      container_port   = each.value.port
    }
  }

  dynamic "service_registries" {
    for_each = each.value.cloud_map ? [aws_service_discovery_service.svc[each.key].arn] : []
    content {
      registry_arn = service_registries.value
    }
  }

  health_check_grace_period_seconds = each.value.target_group == null ? null : 60

  wait_for_steady_state = false

  # After the first deploy, CodePipeline owns the task definition revision.
  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }

  # Target groups must be attached to the ALB before a service can use them,
  # and the execution role needs its policies before tasks start.
  depends_on = [
    aws_lb_listener.https,
    aws_lb_listener_rule.api_host,
    aws_lb_listener_rule.api_path,
    aws_iam_role_policy_attachment.ecs_execution_managed,
    aws_iam_role_policy.ecs_execution_db_password,
  ]
}

# ---------------------------------------------------------------------------
# One-off psql task for inspecting the database (see output "psql_run_task_command").
# Not a service: run it on demand; it prints the query result to /ecs/paylab (prefix psql).
# ---------------------------------------------------------------------------
resource "aws_ecs_task_definition" "psql" {
  family                   = "paylab-psql"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  runtime_platform {
    cpu_architecture        = "X86_64"
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([{
    name      = "psql"
    image     = "public.ecr.aws/docker/library/postgres:16-alpine"
    essential = true
    command = [
      "psql", "-c",
      "SELECT id, handle, balance_kobo FROM wallets ORDER BY id; SELECT id, reference, payer_wallet_id, payee_wallet_id, amount_kobo, status FROM payments ORDER BY id DESC LIMIT 20;"
    ]
    environment = [
      { name = "PGHOST", value = aws_db_instance.paylab.address },
      { name = "PGPORT", value = "5432" },
      { name = "PGDATABASE", value = "paylab" },
      { name = "PGUSER", value = "paylab" },
      { name = "PGSSLMODE", value = "require" },
    ]
    secrets = [{ name = "PGPASSWORD", valueFrom = aws_ssm_parameter.db_password.arn }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.ecs.name
        awslogs-region        = local.region
        awslogs-stream-prefix = "psql"
      }
    }
  }])
}
