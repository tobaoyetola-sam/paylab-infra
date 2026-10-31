# One repository per service: paylab/<service>. Starts empty; the pipelines push the images.
resource "aws_ecr_repository" "svc" {
  for_each = local.services

  name         = "paylab/${each.key}"
  force_delete = true # terraform destroy removes the images too

  image_scanning_configuration {
    scan_on_push = true
  }
}
