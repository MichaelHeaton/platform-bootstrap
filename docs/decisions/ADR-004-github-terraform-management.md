# ADR-004: Manage All GitHub Repositories via Terraform (Except platform-bootstrap)

**Status:** Accepted
**Date:** 2025-05-22
**Deciders:** @MichaelHeaton

## Context

As the number of GitHub repositories grows, manual management of per-repository settings
becomes inconsistent. Branch protection rules, secret scanning, vulnerability alerts, merge
strategy configuration, and CODEOWNERS placement need to be uniform across all repositories.
Without a systematic approach, settings drift over time and security guarantees erode.

## Decision

All GitHub repositories are managed by Terraform using the `integrations/github` provider,
configured in the `terraform/modules/github-repos` module. The module manages:

- Repository creation and settings (`github_repository`)
- Branch protection on `main` (PR required, stale review dismissal, code owner review required)
- CODEOWNERS file initialized for each repository

**platform-bootstrap is explicitly excluded from Terraform management.**

This exclusion is enforced at two levels:

1. A comment at the top of `terraform/main.tf` documents the exclusion and references this ADR.
2. The `github-repos` module validates that no repository list passed to it contains
   `platform-bootstrap` — any such configuration is rejected with a clear error.

**Why platform-bootstrap must be excluded:** This repository is the mechanism by which all
other repositories are managed. If platform-bootstrap's Terraform configuration is broken, or
if the bootstrap has not yet been completed, there is no working pipeline to fix it. Managing
it via Terraform creates a circular dependency: you need it working to manage it. It is the
foundation — it must be manually stable. Terraform managing it would mean it could only be
repaired via itself, which is impossible during a failure scenario.

platform-bootstrap settings are maintained manually and must be audited separately. The
compliance script checks that `platform-bootstrap` does NOT appear in any
`github_repository` managed resource.

## Consequences

- All managed repositories have consistent branch protection, security scanning, and
  CODEOWNERS from the moment of creation.
- Adding a new GitHub repository requires a PR to platform-bootstrap. The
  `terraform-plan` workflow shows exactly what will be created before the PR is approved.
- platform-bootstrap settings must be audited manually on a regular schedule. The compliance
  check enforces that no Terraform resource for platform-bootstrap exists.
- The `pre-publication-audit` workflow (not rulesets) enforces review before any repository
  is set to `visibility = public`, giving a human a final approval step.
- `required_status_checks` are intentionally left unset in the branch protection resource.
  Each repository manages its own required checks to avoid coupling all repositories to a
  single check list.

## Alternatives Considered

- **Manage everything including platform-bootstrap via Terraform:** Creates a circular
  dependency. If the bootstrap is broken, there is no mechanism to repair it. Rejected.
- **Manual repository management for all repos:** Configuration drift is inevitable at scale.
  Security settings become inconsistent. Rejected.
- **GitHub organization-level settings only (ruleset inheritance):** Organization rulesets
  provide some coverage but are not granular enough for per-repository configuration, do not
  manage CODEOWNERS, and do not create repositories. Not sufficient on its own.
- **GitHub Actions `gh` CLI scripts:** Imperative scripts are harder to review, do not
  provide drift detection, and cannot be `terraform plan`-previewed.

## Future State

If GitLab repositories are added to the platform, a separate `terraform-gitlab-repos` module
will be needed. This is deferred pending confirmed GitLab support in the target CI platform.
A placeholder comment exists in `terraform/main.tf`.
