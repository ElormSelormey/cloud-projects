data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

# The AWS-managed S3 Prefix List in this region (solves Defect 6: ECR layer pulls via S3 gateway endpoint)
data "aws_ec2_managed_prefix_list" "s3" {
  filter {
    name   = "prefix-list-name"
    values = ["com.amazonaws.${var.aws_region}.s3"]
  }
}

locals {
  account_id          = data.aws_caller_identity.current.account_id
  region              = data.aws_region.current.name
  azs                 = slice(data.aws_availability_zones.available.names, 0, 2)
  media_bucket_name   = "${var.project}-media-${var.bucket_suffix}"
  logs_bucket_name    = "${var.project}-logs-${var.bucket_suffix}"
  secret_name         = "${var.project}-db"
  log_group_name      = "/ecs/${var.project}"
  athena_database_name = "${replace(var.project, "-", "_")}_audit"
}
