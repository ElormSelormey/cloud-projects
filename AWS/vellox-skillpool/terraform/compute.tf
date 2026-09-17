# -----------------------------------------------------------------------------
# Compute Tier (ECR, CloudWatch, ECS Fargate)
# -----------------------------------------------------------------------------

# 1. Private Container Registry (Amazon ECR)
resource "aws_ecr_repository" "app" {
  name                 = "${var.project}-app"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "${var.project}-app"
  }
}

# 2. CloudWatch Log Group (Created before task registration to avoid Defect 3)
resource "aws_cloudwatch_log_group" "ecs" {
  name              = local.log_group_name
  retention_in_days = var.log_retention_days

  tags = {
    Name = local.log_group_name
  }
}

# 3. Amazon ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = "${var.project}-cluster-01"

  tags = {
    Name = "${var.project}-cluster-01"
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name = aws_ecs_cluster.main.name

  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    base              = 1
    weight            = 100
    capacity_provider = "FARGATE"
  }
}

# 4. ECS Fargate Task Definition
resource "aws_ecs_task_definition" "app" {
  family                   = "${var.project}-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([
    {
      name      = "${var.project}-app"
      image     = "${aws_ecr_repository.app.repository_url}:latest"
      essential = true

      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        }
      ]

      environment = [
        {
          name  = "DB_HOST"
          value = aws_db_instance.mysql.address
        },
        {
          name  = "DB_NAME"
          value = var.db_name
        },
        {
          name  = "STORAGE_MODE"
          value = "s3"
        },
        {
          name  = "S3_BUCKET"
          value = aws_s3_bucket.media.id
        },
        {
          name  = "CLOUDFRONT_DOMAIN"
          value = var.enable_cloudfront ? aws_cloudfront_distribution.main[0].domain_name : ""
        }
      ]

      secrets = [
        {
          name      = "DB_USER"
          valueFrom = "${aws_secretsmanager_secret.db_credentials.arn}:username::"
        },
        {
          name      = "DB_PASSWORD"
          valueFrom = "${aws_secretsmanager_secret.db_credentials.arn}:password::"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
          "awslogs-region"        = local.region
          "awslogs-stream-prefix" = "app"
        }
      }
    }
  ])

  depends_on = [aws_cloudwatch_log_group.ecs]

  tags = {
    Name = "${var.project}-task"
  }
}

# 5. ECS Fargate Service (Behind ALB, Private Subnets, No Public IP)
resource "aws_ecs_service" "app" {
  name            = "${var.project}-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = [for s in aws_subnet.app : s.id]
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "${var.project}-app"
    container_port   = var.container_port
  }

  health_check_grace_period_seconds = 60

  depends_on = [
    aws_lb_listener.http,
    aws_iam_role_policy.ecs_execution_secrets
  ]

  tags = {
    Name = "${var.project}-service"
  }
}
