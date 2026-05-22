# Bootstrap sequence:
#
# Step 1 — First run (no remote state yet):
#   terraform init -backend=false
#   terraform apply   # creates the S3 bucket
#
# Step 2 — Migrate local state to S3:
#   terraform init -reconfigure \
#     -backend-config="bucket=$TF_STATE_BUCKET_NAME" \
#     -backend-config="key=platform-bootstrap/terraform.tfstate" \
#     -backend-config="region=$AWS_REGION"
#
# See docs/runbooks/02-bootstrap.md — "Migrate local state to S3"

terraform {
  backend "s3" {
    key          = "platform-bootstrap/terraform.tfstate"
    use_lockfile = true
    encrypt      = true
    # bucket and region supplied via -backend-config at init time
    # See docs/runbooks/02-bootstrap.md for exact commands
  }
}
