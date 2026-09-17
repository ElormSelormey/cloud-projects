# -----------------------------------------------------------------------------
# Audit & Compliance (AWS CloudTrail & Amazon Athena In-Place Queries)
# -----------------------------------------------------------------------------

# 1. CloudTrail with Object-Level S3 Data Events
resource "aws_cloudtrail" "audit" {
  count = var.enable_cloudtrail ? 1 : 0

  name                          = "${var.project}-audit-trail-01"
  s3_bucket_name                = aws_s3_bucket.logs.id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true

  # Advanced Event Selector 1: Management events across ECS, RDS, etc.
  advanced_event_selector {
    name = "Management events"
    field_selector {
      field  = "eventCategory"
      equals = ["Management"]
    }
  }

  # Advanced Event Selector 2: Data events on media bucket (answers who accessed what & when)
  advanced_event_selector {
    name = "Media bucket object access"
    field_selector {
      field  = "eventCategory"
      equals = ["Data"]
    }
    field_selector {
      field  = "resources.type"
      equals = ["AWS::S3::Object"]
    }
    field_selector {
      field       = "resources.ARN"
      starts_with = ["${aws_s3_bucket.media.arn}/"]
    }
  }

  depends_on = [aws_s3_bucket_policy.logs_cloudtrail]

  tags = {
    Name = "${var.project}-audit-trail-01"
  }
}

# 2. Athena Workgroup for Auditors (Direct SQL Queries Over S3 Logs)
resource "aws_athena_workgroup" "auditors" {
  count = var.enable_athena ? 1 : 0

  name        = "${var.project}-auditors"
  description = "Auditor queries over CloudTrail logs in place"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = "s3://${aws_s3_bucket.logs.id}/athena-results/"
      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }

  tags = {
    Name = "${var.project}-auditors"
  }
}

# 3. Athena Audit Database
resource "aws_athena_database" "audit" {
  count = var.enable_athena ? 1 : 0

  name   = local.athena_database_name
  bucket = aws_s3_bucket.logs.id

  depends_on = [aws_athena_workgroup.auditors]
}
