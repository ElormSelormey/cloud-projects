variable "project" {
  description = "Project name identifier used across all resources"
  type        = string
  default     = "vellox-skillpool"
}

variable "environment" {
  description = "Deployment environment name"
  type        = string
  default     = "poc"
}

variable "aws_region" {
  description = "Target AWS Region"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnets" {
  description = "CIDR blocks for public subnets (ALB tier)"
  type        = list(string)
  default     = ["10.0.0.0/20", "10.0.16.0/20"]
}

variable "app_subnets" {
  description = "CIDR blocks for private application subnets (ECS tier)"
  type        = list(string)
  default     = ["10.0.128.0/20", "10.0.144.0/20"]
}

variable "data_subnets" {
  description = "CIDR blocks for isolated data subnets (RDS tier)"
  type        = list(string)
  default     = ["10.0.200.0/24", "10.0.201.0/24"]
}

variable "bucket_suffix" {
  description = "Globally unique suffix for S3 bucket naming"
  type        = string
  default     = "001"
}

variable "db_name" {
  description = "Initial MySQL database name"
  type        = string
  default     = "skillpool"
}

variable "db_username" {
  description = "Master username for RDS MySQL"
  type        = string
  default     = "admin"
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t4g.micro"
}

variable "db_allocated_storage" {
  description = "Allocated storage for RDS MySQL in GB"
  type        = number
  default     = 20
}

variable "db_multi_az" {
  description = "Deploy RDS as Multi-AZ for high availability"
  type        = bool
  default     = false
}

variable "container_port" {
  description = "Application port exposed by the container"
  type        = number
  default     = 5000
}

variable "task_cpu" {
  description = "Fargate CPU units (256 = 0.25 vCPU)"
  type        = string
  default     = "256"
}

variable "task_memory" {
  description = "Fargate memory in MiB (512 = 0.5 GB)"
  type        = string
  default     = "512"
}

variable "desired_count" {
  description = "Number of ECS tasks to maintain"
  type        = number
  default     = 1
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 7
}

variable "enable_cloudfront" {
  description = "Enable CloudFront dual-origin distribution"
  type        = bool
  default     = true
}

variable "enable_cloudtrail" {
  description = "Enable CloudTrail trail with S3 data events"
  type        = bool
  default     = true
}

variable "enable_athena" {
  description = "Enable Athena workgroup and audit database"
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# Teardown & Cost Management Controls (Equivalent to Teardown Script Flags)
# -----------------------------------------------------------------------------

variable "enable_interface_endpoints" {
  description = "Enable billable VPC Interface Endpoints. Set to false to tear down only endpoints (saves ~$56/mo) between work sessions (equivalent to --endpoints-only)."
  type        = bool
  default     = true
}

variable "skip_final_snapshot" {
  description = "Skip final RDS database snapshot on destruction. Set to false to take a final snapshot before teardown (equivalent to --keep-data)."
  type        = bool
  default     = true
}

variable "force_destroy_buckets" {
  description = "Allow Terraform to delete S3 buckets containing data on teardown. Set to false to safeguard persistent data."
  type        = bool
  default     = true
}
