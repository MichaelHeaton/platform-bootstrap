# ADR-003: Single S3 Bucket with Flat Folder Structure for All Terraform State

**Status:** Accepted
**Date:** 2025-05-22
**Deciders:** @MichaelHeaton

## Context

Multiple projects, environments, and clouds will each have their own Terraform state file. A
decision is needed on how to organize those state files — specifically: how many S3 buckets to
use, how to name the bucket, and how to structure object keys within it.

## Decision

Use a single S3 bucket with a recognisable but unique name. State objects are organized with
flat folder prefixes following the convention:

```
{environment}-{cloud}-{function}/terraform.tfstate
```

Examples:
- `prod-aws-vpc/terraform.tfstate`
- `dev-homelab-plex/terraform.tfstate`
- `platform-bootstrap/terraform.tfstate` (this repository's own state)

The same key pattern is used as the pipeline identifier in `var.pipelines`, ensuring the IAM
role name and the S3 state path are always in sync without any extra variables.

**Rationale for bucket naming:** The only hard requirement is global uniqueness across all AWS
accounts. A name like `{owner}-tfstate` (e.g., `mccleaton-tfstate`) satisfies this while
remaining recognisable in billing reports, CloudWatch logs, and CLI output without needing to
look it up. Security-through-obscurity (random strings) was considered and rejected — the
actual security controls are the private ACL, public access block, HTTPS-only bucket policy,
and IAM path scoping. The name is stored as a GitHub Actions variable (`TF_STATE_BUCKET_NAME`)
rather than being hardcoded in any source file.

**Rationale for flat folder structure:** A single prefix level is simple to reason about. IAM
policies can match exact prefixes without wildcards or multiple condition blocks. The naming
convention encodes all relevant context — environment, cloud, and function — directly in the
path so the object key is self-describing.

## Consequences

- IAM policies use exact prefix matching — no wildcards at the path level. The `oidc-roles`
  module generates one policy per pipeline scoped to exactly `${key}/*`.
- All state paths are visible in one listing: `aws s3 ls s3://BUCKET/`
- The bucket name must be stored and distributed securely (GitHub variable, not source code).
- Adding a new project requires adding its state folder prefix via a new entry in
  `var.pipelines`. The `terraform-apply` workflow then creates the IAM role automatically.
- The bucket has `prevent_destroy = true` in Terraform to guard against accidental deletion.

## Alternatives Considered

- **One bucket per environment (prod, dev, staging):** More isolation but higher per-bucket
  cost and management overhead. IAM boundary conditions are more complex to express.
- **One bucket per project:** Extreme fragmentation. Difficult to track, audit, or apply
  uniform policy. Cost of many nearly-empty buckets adds up.
- **Hierarchical prefixes (`env/cloud/function/terraform.tfstate`):** Encodes the same
  information but requires multi-level IAM prefix conditions (`s3:prefix` with nested paths).
  Flat structure is equivalent and simpler.
- **Terraform Cloud workspaces:** Adds an external service dependency and recurring cost.
  See ADR-001.

## Future State

Cross-region replication is deferred pending cost analysis. Data transfer costs and the
recovery time benefit must be evaluated before enabling replication. A placeholder comment
exists in `terraform/modules/s3-state/main.tf`.

If regulatory requirements mandate data residency in a specific region, per-region buckets
may be required. This would mean updating the IAM policies and the backend configuration
pattern, but the folder structure within each bucket would remain the same.
