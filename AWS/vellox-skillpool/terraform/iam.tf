# -----------------------------------------------------------------------------
# IAM Roles & Segmented Access Groups
# -----------------------------------------------------------------------------

# ECS Trust Policy Document
data "aws_iam_policy_document" "ecs_tasks_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# 1. ECS Task Role (What the running container is permitted to do)
resource "aws_iam_role" "ecs_task_role" {
  name               = "${var.project}-ecs-s3-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

resource "aws_iam_role_policy" "ecs_task_policy" {
  name = "${var.project}-task-access"
  role = aws_iam_role.ecs_task_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = "arn:aws:s3:::${local.media_bucket_name}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${local.media_bucket_name}"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${local.region}:${local.account_id}:log-group:${local.log_group_name}*"
      }
    ]
  })
}

# 2. ECS Task Execution Role (What ECS agent does on task's behalf)
resource "aws_iam_role" "ecs_execution_role" {
  name               = "${var.project}-ecs-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

resource "aws_iam_role_policy_attachment" "ecs_execution_standard" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Scoped secret retrieval with wildcard suffix for Secrets Manager
resource "aws_iam_role_policy" "ecs_execution_secrets" {
  name = "${var.project}-secrets-access"
  role = aws_iam_role.ecs_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = "arn:aws:secretsmanager:${local.region}:${local.account_id}:secret:${var.project}-db-*"
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Four Segmented Human Access Groups
# -----------------------------------------------------------------------------

# Group 1: Multimedia Users
resource "aws_iam_group" "multimedia" {
  name = "${var.project}-multimedia-users"
}

resource "aws_iam_group_policy" "multimedia" {
  name  = "${var.project}-multimedia-access"
  group = aws_iam_group.multimedia.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:DeleteObject"
        ]
        Resource = [
          "arn:aws:s3:::${local.media_bucket_name}",
          "arn:aws:s3:::${local.media_bucket_name}/*"
        ]
      }
    ]
  })
}

# Group 2: AppDev & DevOps Users
resource "aws_iam_group" "appdev" {
  name = "${var.project}-appdev-devops-users"
}

resource "aws_iam_group_policy" "appdev" {
  name  = "${var.project}-appdev-access"
  group = aws_iam_group.appdev.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecs:*",
          "ecr:*",
          "logs:*",
          "elasticloadbalancing:Describe*",
          "iam:PassRole"
        ]
        Resource = "*"
      }
    ]
  })
}

# Group 3: Database Users
resource "aws_iam_group" "database" {
  name = "${var.project}-db-users"
}

resource "aws_iam_group_policy" "database" {
  name  = "${var.project}-db-access"
  group = aws_iam_group.database.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "rds:Describe*",
          "ssm:StartSession"
        ]
        Resource = "*"
      }
    ]
  })
}

# Group 4: Compliance Auditors
resource "aws_iam_group" "auditors" {
  name = "${var.project}-auditors"
}

resource "aws_iam_group_policy" "auditors" {
  name  = "${var.project}-auditor-access"
  group = aws_iam_group.auditors.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "athena:*",
          "glue:Get*",
          "glue:Batch*"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::${local.logs_bucket_name}",
          "arn:aws:s3:::${local.logs_bucket_name}/*"
        ]
      }
    ]
  })
}
