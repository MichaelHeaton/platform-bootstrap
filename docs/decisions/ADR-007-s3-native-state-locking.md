# ADR-007: S3 Native State Locking over DynamoDB

**Status:** Accepted
**Date:** 2025-05-22
**Deciders:** @MichaelHeaton

## Context

Terraform's S3 backend historically required a separate DynamoDB table to implement state
locking. The DynamoDB table stored a lock record that prevented two `terraform apply` runs
from modifying the same state file concurrently. While this works, it adds a resource that
must be created before Terraform can use the backend, costs money at low traffic volumes,
and requires DynamoDB permissions on every IAM role that runs Terraform.

Terraform 1.10 introduced native S3 state locking using S3 conditional writes (`If-None-Match`
on the `.tflock` object). This eliminates the DynamoDB dependency entirely.

## Decision

Use S3 native state locking by setting `use_lockfile = true` in the backend configuration.
No DynamoDB table is created or required.

```hcl
terraform {
  backend "s3" {
    key          = "platform-bootstrap/terraform.tfstate"
    use_lockfile = true
    encrypt      = true
  }
}
```

Terraform >= 1.10.0 is already required for other reasons and is enforced in
`terraform/versions.tf`.

## Consequences

- Eliminates a separate AWS resource (DynamoDB table) from the bootstrap sequence. One fewer
  resource to create manually before Terraform can manage itself.
- Simpler IAM policies — no `dynamodb:GetItem`, `dynamodb:PutItem`, `dynamodb:DeleteItem`
  permissions needed on any role.
- Lock objects appear in S3 as `<state-key>.tflock` (e.g.,
  `platform-bootstrap/terraform.tfstate.tflock`). They are automatically removed on clean
  job completion.
- If a pipeline job is interrupted before Terraform can release the lock, the lock object
  remains. Manual clearance: `aws s3 rm s3://$BUCKET/$KEY.tflock`
- Requires Terraform >= 1.10.0. This is enforced with `required_version = ">= 1.10.0"` in
  `terraform/versions.tf`. Older Terraform versions will fail at `init` with a clear error.
- DynamoDB locking remains available as a backward-compatible option — adding
  `dynamodb_table` to the backend config reverts to the classic approach if needed.

## Alternatives Considered

- **DynamoDB + S3 (classic approach):** Works correctly and is well-understood. The
  DynamoDB table adds approximately $0.25/month at minimal usage (on-demand billing), which
  is not the concern — the concern is bootstrapping complexity. With DynamoDB you must create
  the table before `terraform init` can succeed, adding a manual step to every new environment.
  Superseded by native locking for Terraform >= 1.10.
- **No locking:** Acceptable only for single-operator setups where concurrent runs are
  impossible by convention. Risky as soon as more than one pipeline can trigger a `plan` or
  `apply` simultaneously. Rejected.

## Future State

If multiple operators routinely run concurrent `terraform plan` operations against the same
state file, test that S3 native conditional writes handle lock contention gracefully under
load. If issues arise (e.g., eventual-consistency edge cases at high concurrency), the
DynamoDB table can be re-added alongside `use_lockfile = true` — the two mechanisms are
compatible. This scenario is considered unlikely at current scale.
