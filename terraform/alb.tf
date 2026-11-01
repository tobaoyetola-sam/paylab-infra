# Two modes (see var.domain_zone):
#   domain set   -> HTTPS on pay./api. hostnames. The public zone and the ISSUED ACM certificate
#                   (for web_host, or certificate_domain such as a *.zone wildcard) are
#                   PERSISTENT and not managed here; they are only looked up.
#   domain empty -> plain HTTP on the ALB's own DNS name. No zone, no certificate needed.
data "aws_route53_zone" "public" {
  count        = local.use_domain ? 1 : 0
  name         = var.domain_zone
  private_zone = false
}

data "aws_acm_certificate" "paylab" {
  count       = local.use_domain ? 1 : 0
  domain      = var.certificate_domain != "" ? var.certificate_domain : var.web_host
  statuses    = ["ISSUED"]
  most_recent = true
}

resource "aws_lb" "paylab" {
  name               = "paylab-alb"
  load_balancer_type = "application"
  internal           = false
  subnets            = data.aws_subnets.default.ids
  security_groups    = [aws_security_group.alb.id]
}

# Type "ip" because Fargate tasks get their own IP (awsvpc mode).
resource "aws_lb_target_group" "api" {
  name        = "paylab-tg"
  port        = 8080
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = data.aws_vpc.default.id

  health_check {
    path              = "/health"
    interval          = 15
    healthy_threshold = 2
  }
}

resource "aws_lb_target_group" "web" {
  name        = "paylab-web-tg"
  port        = 3000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = data.aws_vpc.default.id

  health_check {
    path              = "/health"
    interval          = 15
    healthy_threshold = 2
  }
}

# :80 -> 301 redirect to HTTPS (domain mode), or straight to web (no-domain mode)
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.paylab.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = local.use_domain ? "redirect" : "forward"
    target_group_arn = local.use_domain ? null : aws_lb_target_group.web.arn

    dynamic "redirect" {
      for_each = local.use_domain ? [1] : []
      content {
        protocol    = "HTTPS"
        port        = "443"
        status_code = "HTTP_301"
      }
    }
  }
}

# :443 (domain mode only). Every hostname we serve has its own rule below;
# anything else that reaches the ALB (another name, the raw ALB DNS) gets a 404.
resource "aws_lb_listener" "https" {
  count             = local.use_domain ? 1 : 0
  load_balancer_arn = aws_lb.paylab.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = data.aws_acm_certificate.paylab[0].arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not found"
      status_code  = "404"
    }
  }
}

# api.<domain> -> api-gateway (domain mode only)
resource "aws_lb_listener_rule" "api_host" {
  count        = local.use_domain ? 1 : 0
  listener_arn = aws_lb_listener.https[0].arn
  priority     = 10

  condition {
    host_header {
      values = [var.api_host]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

# <web host>/api/* -> api-gateway (the page calls the API on its own origin).
# Domain mode also matches the host; with no domain there is only one host anyway.
resource "aws_lb_listener_rule" "api_path" {
  listener_arn = local.use_domain ? aws_lb_listener.https[0].arn : aws_lb_listener.http.arn
  priority     = 20

  condition {
    path_pattern {
      values = ["/api/*"]
    }
  }

  dynamic "condition" {
    for_each = local.use_domain ? [1] : []
    content {
      host_header {
        values = [var.web_host]
      }
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

# <web host> -> web (domain mode only; with no domain the :80 default does this)
resource "aws_lb_listener_rule" "web_host" {
  count        = local.use_domain ? 1 : 0
  listener_arn = aws_lb_listener.https[0].arn
  priority     = 30

  condition {
    host_header {
      values = [var.web_host]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

# Public DNS: alias A records -> ALB. Only these two records are managed;
# the zone, its NS/SOA and the certificate's validation CNAMEs are left alone.
resource "aws_route53_record" "alias" {
  for_each = local.use_domain ? toset([var.web_host, var.api_host]) : toset([])

  zone_id         = data.aws_route53_zone.public[0].zone_id
  name            = each.value
  type            = "A"
  allow_overwrite = true # take over records left behind by the bash scripts

  alias {
    name                   = aws_lb.paylab.dns_name
    zone_id                = aws_lb.paylab.zone_id
    evaluate_target_health = false
  }
}
