# -----------------------------------------------------------------------------
# VPC & Subnets (3-Tier Architecture)
# -----------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project}-vpc"
  }
}

# Public Subnets (ALB Tier)
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnets[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project}-subnet-public${count.index + 1}-${local.azs[count.index]}"
    Tier = "public"
  }
}

# Private Application Subnets (ECS Fargate Tier)
resource "aws_subnet" "app" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.app_subnets[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project}-subnet-private${count.index + 1}-${local.azs[count.index]}"
    Tier = "application"
  }
}

# Isolated Data Subnets (RDS MySQL Tier)
resource "aws_subnet" "data" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.data_subnets[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project}-rds-subnet-az0${count.index + 1}"
    Tier = "data"
  }
}

# -----------------------------------------------------------------------------
# Internet Gateway & Routing
# -----------------------------------------------------------------------------

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project}-igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "${var.project}-rtb-public"
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private Route Tables (one per AZ)
resource "aws_route_table" "private" {
  count  = 2
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project}-rtb-private${count.index + 1}-${local.azs[count.index]}"
  }
}

# Associate App and Data subnets to their respective AZ private route table
resource "aws_route_table_association" "app" {
  count          = 2
  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

resource "aws_route_table_association" "data" {
  count          = 2
  subnet_id      = aws_subnet.data[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# -----------------------------------------------------------------------------
# VPC Endpoints (NAT-Free Design)
# -----------------------------------------------------------------------------

# 1. S3 Gateway Endpoint (Associated with BOTH private route tables)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${local.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [for rtb in aws_route_table.private : rtb.id]

  tags = {
    Name = "${var.project}-vpc-s3-endpoints-01"
  }
}

# 2. Interface Endpoints (ecr.api, ecr.dkr, logs, secretsmanager)
locals {
  interface_services = ["ecr.api", "ecr.dkr", "logs", "secretsmanager"]
}

resource "aws_vpc_endpoint" "interfaces" {
  for_each            = toset(local.interface_services)
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${local.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for s in aws_subnet.app : s.id]
  security_group_ids  = [aws_security_group.endpoint.id]
  private_dns_enabled = true

  tags = {
    Name = "${var.project}-${each.key}-endpoint-01"
  }
}
