# -----------------------------------------------------------------------------
# Database Tier (Secrets Manager & Amazon RDS MySQL)
# -----------------------------------------------------------------------------

# Generate high-entropy master database password
resource "random_password" "db_password" {
  length           = 24
  special          = false
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# AWS Secrets Manager Secret
resource "aws_secretsmanager_secret" "db_credentials" {
  name                    = local.secret_name
  description             = "Velloxx SkillPool RDS master credentials"
  recovery_window_in_days = 0 # Immediate deletion on destroy for clean teardown

  tags = {
    Name = local.secret_name
  }
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db_password.result
  })
}

# DB Subnet Group across isolated data subnets
resource "aws_db_subnet_group" "rds" {
  name        = "${var.project}-db-subnet-group"
  description = "SkillPool data tier isolated subnets"
  subnet_ids  = [for s in aws_subnet.data : s.id]

  tags = {
    Name = "${var.project}-db-subnet-group"
  }
}

# RDS MySQL Instance
resource "aws_db_instance" "mysql" {
  identifier                  = "${var.project}-db-01"
  instance_class              = var.db_instance_class
  engine                      = "mysql"
  engine_version              = "8.0"
  allocated_storage           = var.db_allocated_storage
  storage_type                = "gp3"
  db_name                     = var.db_name
  username                    = var.db_username
  password                    = random_password.db_password.result
  db_subnet_group_name        = aws_db_subnet_group.rds.name
  vpc_security_group_ids      = [aws_security_group.rds.id]
  publicly_accessible         = false
  backup_retention_period     = 7
  storage_encrypted           = true
  multi_az                    = var.db_multi_az
  auto_minor_version_upgrade  = true
  skip_final_snapshot         = var.skip_final_snapshot
  final_snapshot_identifier   = var.skip_final_snapshot ? null : "${var.project}-db-final-snapshot"
  deletion_protection         = var.environment == "poc" ? false : true

  tags = {
    Name = "${var.project}-db-01"
  }
}
