# ADR-008: Migrate All GitLab Repositories to GitHub

**Status:** Accepted
**Date:** 2026-05-23
**Deciders:** @MichaelHeaton

## Context

The platform currently operates a set of repositories on GitLab alongside the GitHub-native
infrastructure established in ADR-004. This split creates two sources of truth for source code,
two CI systems to operate, and two sets of access controls to maintain. The platform-bootstrap
repository, all AWS infrastructure, and all CI/CD pipelines already target GitHub. GitLab
repositories sit outside Terraform management, outside the compliance checks, and outside the
OIDC authentication model that governs every other pipeline.

Running two hosting platforms for a single-team platform adds overhead without benefit. The
GitLab free tier does not provide the organisation-level controls that GitHub provides, and the
existing investment in Terraform-managed GitHub repository configuration (branch protection,
CODEOWNERS, secret scanning) cannot be extended to GitLab without a separate provider and a
separate CI platform.

## Decision

Migrate all GitLab repositories to GitHub. Each migrated repository is registered in
`terraform/main.tf` via `var.managed_repositories`, bringing it under the same branch
protection, CODEOWNERS, and compliance checks that apply to every other managed repository.
GitLab CI pipelines are converted to GitHub Actions. Open issues and merge requests are
migrated to GitHub Issues and Pull Requests before the GitLab repositories are archived.

The migration is performed in phases: inventory, Terraform registration, git mirror, issue
migration, CI conversion, secret migration, and final archive. The full procedure is in
`docs/runbooks/04-gitlab-github-migration.md`.

GitLab repositories are **archived** (not deleted) for a minimum of 90 days after migration
completes, to allow any missed references to be discovered and corrected.

## Consequences

- All source code, history, issues, and pipelines are consolidated on a single platform.
- Every migrated repository is immediately under Terraform management: branch protection and
  CODEOWNERS are enforced from the first push, and the compliance check covers them.
- GitLab CI pipelines must be converted to GitHub Actions. This is a one-time cost; there is no
  ongoing translation layer.
- Open GitLab issues and merge requests must be exported and re-created on GitHub before
  migration cutover. Closed items are not migrated — they remain accessible on the archived
  GitLab repository.
- GitLab-specific features with no GitHub equivalent (GitLab Pages, GitLab Packages) must be
  evaluated per-repository and replaced or dropped before migration.
- Existing GitLab clone URLs will stop receiving pushes after cutover. Any CI systems, deploy
  keys, webhooks, or local clones pointing at GitLab must be updated.
- The `DEFERRED: GitLab provider` placeholder in `terraform/main.tf` is removed as part of
  this migration — no `terraform-gitlab-repos` module will be built.

## Alternatives Considered

- **Keep both platforms running in parallel indefinitely:** Doubles access control audit
  surface, keeps CI logic split across two systems, and prevents the compliance checks from
  covering all repositories. Rejected.
- **Migrate GitHub repos to GitLab instead:** GitLab does not integrate with the existing OIDC
  trust, S3 backend, or Terraform management layer. Would require rebuilding the entire
  bootstrap from scratch. Rejected.
- **Use a Git hosting abstraction layer:** Adds complexity and a third system without solving
  the CI split problem. Rejected.

## Future State

Once all repositories are on GitHub and the GitLab organisation is archived, the
`DEFERRED: GitLab provider` placeholder in `terraform/main.tf` and the corresponding note in
this ADR are removed. The GitLab organisation can be fully deprovisioned after the 90-day
archive window closes with no outstanding reference issues.
