# ADR-001: S3 for Terraform Remote State Storage

**Status:** Accepted
**Date:** 2025-05-22
**Deciders:** @MichaelHeaton

## Context

Terraform remote state storage is required to support team collaboration, prevent concurrent
state corruption, and provide a rollback path. The storage backend must be accessible from
GitHub Actions pipelines running in AWS, support state locking, and integrate cleanly with
the OIDC authentication model chosen in ADR-002.

## Decision

Use AWS S3 as the Terraform remote state backend with native state locking (Terraform 1.10+).
The backend is configured with `use_lockfile = true` and `encrypt = true`. Bucket name, region,
and key are supplied at `terraform init` time via `-backend-config` flags rather than hardcoded
in source, so the same backend block works across all environments.

## Consequences

- State is always in S3, accessible from any GitHub Actions runner with valid OIDC credentials.
- Versioning is enabled on the bucket, providing a rollback path for corrupted or accidentally
  modified state.
- Native S3 locking (via conditional writes on the `.tflock` object) removes the need for a
  separate DynamoDB table. See ADR-007 for the locking decision.
- All pipelines must have `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, and
  `s3:ListBucket` permissions on the appropriate state path. IAM policies are managed by the
  `oidc-roles` module.
- The bucket enforces HTTPS-only access via a bucket policy (`DenyNonHTTPS` statement) and
  blocks all public access.

## Alternatives Considered

- **Terraform Cloud:** Adds recurring cost, introduces an external service dependency, and
  complicates the OIDC trust setup. Not chosen for a single-team, AWS-native deployment.
- **Azure Blob Storage:** Adds multi-cloud complexity before any Azure workloads exist. Deferred
  pending confirmed need.
- **DynamoDB + S3 locking:** The prior standard approach. Superseded by native S3 locking in
  Terraform 1.10 — see ADR-007.
- **Git-based state (terraform-git-backend):** Does not support concurrent access, struggles
  with large state files, and leaks sensitive output values into commit history.

## Future State

Cross-region S3 replication is deferred pending cost analysis (data transfer costs vs. recovery
time improvement). A placeholder comment exists in `terraform/modules/s3-state/main.tf`.

Multi-account state management (separate buckets or prefixes per AWS account) is deferred
pending AWS Organizations adoption — see ADR-006.
