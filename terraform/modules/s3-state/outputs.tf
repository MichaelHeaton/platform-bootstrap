output "bucket_id" {
  description = "S3 bucket ID"
  value       = aws_s3_bucket.state.id
}

output "bucket_arn" {
  description = "S3 bucket ARN"
  value       = aws_s3_bucket.state.arn
}
