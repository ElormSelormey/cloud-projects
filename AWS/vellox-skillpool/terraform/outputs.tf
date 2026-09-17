output "vpc_id" {
  description = "The ID of the VPC"
  value       = aws_vpc.main.id
}

output "alb_dns_name" {
  description = "Public DNS name of the Application Load Balancer"
  value       = aws_lb.main.dns_name
}

output "application_url" {
  description = "Direct HTTP Application URL via ALB"
  value       = "http://${aws_lb.main.dns_name}"
}

output "cloudfront_domain_name" {
  description = "Domain name of the CloudFront CDN distribution"
  value       = var.enable_cloudfront ? aws_cloudfront_distribution.main[0].domain_name : null
}

output "cloudfront_url" {
  description = "Secure HTTPS URL via CloudFront CDN"
  value       = var.enable_cloudfront ? "https://${aws_cloudfront_distribution.main[0].domain_name}" : null
}

output "rds_endpoint" {
  description = "RDS MySQL connection endpoint address"
  value       = aws_db_instance.mysql.address
}

output "media_bucket_name" {
  description = "S3 bucket storing candidate multimedia"
  value       = aws_s3_bucket.media.id
}

output "logs_bucket_name" {
  description = "S3 bucket storing CloudTrail audit logs"
  value       = aws_s3_bucket.logs.id
}

output "ecr_repository_url" {
  description = "URL of the private Amazon ECR repository"
  value       = aws_ecr_repository.app.repository_url
}

output "athena_workgroup" {
  description = "Athena workgroup configured for compliance queries"
  value       = var.enable_athena ? aws_athena_workgroup.auditors[0].name : null
}
