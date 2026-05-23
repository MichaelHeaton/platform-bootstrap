variable "bucket_name" {
  type        = string
  description = "Name of the S3 bucket. Should be opaque/non-descriptive per ADR-003."
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to all resources in this module."
  default     = {}
}
