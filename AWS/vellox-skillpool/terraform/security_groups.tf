# -----------------------------------------------------------------------------
# Security Groups (Chained Least-Privilege Reference Architecture)
# Decoupled via standalone rules to prevent Terraform DAG cycles
# -----------------------------------------------------------------------------

# 1. Application Load Balancer Security Group
resource "aws_security_group" "alb" {
  name        = "${var.project}-alb-sg"
  description = "Public entry point for the ALB"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project}-alb-sg"
  }
}

resource "aws_security_group_rule" "alb_ingress_http" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "HTTP from internet"
  security_group_id = aws_security_group.alb.id
}

resource "aws_security_group_rule" "alb_ingress_https" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "HTTPS from internet"
  security_group_id = aws_security_group.alb.id
}

resource "aws_security_group_rule" "alb_egress_to_ecs" {
  type                     = "egress"
  from_port                = var.container_port
  to_port                  = var.container_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.ecs.id
  description              = "Forward to ECS application containers"
  security_group_id        = aws_security_group.alb.id
}

# 2. ECS Fargate Application Security Group
resource "aws_security_group" "ecs" {
  name        = "${var.project}-ecs-sg"
  description = "ECS Fargate application tier"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project}-ecs-sg"
  }
}

resource "aws_security_group_rule" "ecs_ingress_from_alb" {
  type                     = "ingress"
  from_port                = var.container_port
  to_port                  = var.container_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
  description              = "Inbound traffic from ALB only"
  security_group_id        = aws_security_group.ecs.id
}

# Defect 6 Fix: Egress scoped to AWS-managed S3 Prefix List
resource "aws_security_group_rule" "ecs_egress_s3_prefix_list" {
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  prefix_list_ids   = [data.aws_ec2_managed_prefix_list.s3.id]
  description       = "S3 and ECR layers via S3 gateway endpoint"
  security_group_id = aws_security_group.ecs.id
}

resource "aws_security_group_rule" "ecs_egress_to_endpoints" {
  type                     = "egress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.endpoint.id
  description              = "HTTPS to VPC interface endpoints"
  security_group_id        = aws_security_group.ecs.id
}

resource "aws_security_group_rule" "ecs_egress_to_rds" {
  type                     = "egress"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.rds.id
  description              = "MySQL access to RDS"
  security_group_id        = aws_security_group.ecs.id
}

resource "aws_security_group_rule" "ecs_egress_dns_udp" {
  type              = "egress"
  from_port         = 53
  to_port           = 53
  protocol          = "udp"
  cidr_blocks       = [var.vpc_cidr]
  description       = "VPC DNS resolver (UDP)"
  security_group_id = aws_security_group.ecs.id
}

resource "aws_security_group_rule" "ecs_egress_dns_tcp" {
  type              = "egress"
  from_port         = 53
  to_port           = 53
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr]
  description       = "VPC DNS resolver (TCP)"
  security_group_id = aws_security_group.ecs.id
}

# 3. RDS MySQL Security Group
resource "aws_security_group" "rds" {
  name        = "${var.project}-rds-sg"
  description = "RDS MySQL data tier"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project}-rds-sg"
  }
}

resource "aws_security_group_rule" "rds_ingress_from_ecs" {
  type                     = "ingress"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.ecs.id
  description              = "MySQL traffic from ECS application tier only"
  security_group_id        = aws_security_group.rds.id
}

# 4. VPC Interface Endpoints Security Group
resource "aws_security_group" "endpoint" {
  name        = "${var.project}-endpoint-sg"
  description = "VPC interface endpoint access"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project}-endpoint-sg"
  }
}

resource "aws_security_group_rule" "endpoint_ingress_from_ecs" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.ecs.id
  description              = "HTTPS from ECS application tasks"
  security_group_id        = aws_security_group.endpoint.id
}
