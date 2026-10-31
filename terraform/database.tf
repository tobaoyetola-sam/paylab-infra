# Letters and digits only: safe for RDS (which rejects / @ " and space) and for URLs.
resource "random_password" "db" {
  length  = 32
  special = false
}

# The password lives in SSM Parameter Store; ECS injects it as DB_PASSWORD.
# (It is also in the Terraform state file, another reason to keep the state private.)
resource "aws_ssm_parameter" "db_password" {
  name        = "/paylab/db/password"
  description = "PayLab RDS master password"
  type        = "SecureString" # encrypted with the AWS-managed key alias/aws/ssm
  value       = random_password.db.result
}

resource "aws_db_instance" "paylab" {
  identifier     = "paylab-db"
  engine         = "postgres"
  engine_version = "16"
  instance_class = "db.t4g.micro"

  allocated_storage = 20
  storage_type      = "gp3"

  db_name  = "paylab"
  username = "paylab"
  password = random_password.db.result

  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period = 0
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true
}

resource "aws_ssm_parameter" "db_host" {
  name        = "/paylab/db/host"
  description = "PayLab RDS endpoint"
  type        = "String"
  value       = aws_db_instance.paylab.address
}
