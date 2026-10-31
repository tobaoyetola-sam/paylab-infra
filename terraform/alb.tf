# PERSISTENT, not managed here: the public zone (delegated from Cloudflare) and the
# ISSUED ACM certificate for pay. + api. (created once by 00-dns-cert.sh).
data "aws_route53_zone" "public" {
  name         = var.domain_zone
  private_zone = false
}

data "aws_acm_certificate" "paylab" {
  domain      = var.web_host
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

# :80 -> 301 redirect to HTTPS
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.paylab.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      protocol    = "HTTPS"
      port        = "443"
      status_code = "HTTP_301"
    }
  }
}

# :443 -> web by default
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.paylab.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = data.aws_acm_certificate.paylab.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

# api.lab.aricxpoint.co -> api-gateway
resource "aws_lb_listener_rule" "api_host" {
  listener_arn = aws_lb_listener.https.arn
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

# pay.lab.aricxpoint.co/api/* -> api-gateway (the page calls the API on its own origin)
resource "aws_lb_listener_rule" "api_path" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 20

  condition {
    path_pattern {
      values = ["/api/*"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

# Public DNS: alias A records -> ALB. Only these two records are managed;
# the zone, its NS/SOA and the certificate's validation CNAMEs are left alone.
resource "aws_route53_record" "alias" {
  for_each = toset([var.web_host, var.api_host])

  zone_id         = data.aws_route53_zone.public.zone_id
  name            = each.value
  type            = "A"
  allow_overwrite = true # take over records left behind by the bash scripts

  alias {
    name                   = aws_lb.paylab.dns_name
    zone_id                = aws_lb.paylab.zone_id
    evaluate_target_health = false
  }
}
