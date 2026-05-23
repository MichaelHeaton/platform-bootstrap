# ADR-006: Terraform Modules as Subdirectories (Not Separate Repos)

**Status:** Accepted
**Date:** 2025-05-22
**Deciders:** @MichaelHeaton

## Context

Terraform modules can be versioned and published to the Terraform Registry (or a private
registry) from separate repositories, or they can live as subdirectories within the same
repository that consumes them. The choice affects development velocity, versioning overhead,
and the blast radius of a module change.

## Decision

Start with modules as subdirectories under `terraform/modules/`. Module extraction to
separate repositories is documented as future state with a clear trigger condition.

Current module structure:

```
terraform/
  modules/
    s3-state/       — S3 bucket and bucket policy
    oidc-roles/     — OIDC provider, IAM roles, IAM policies
    github-repos/   — GitHub repository management
```

Module source references use relative paths:

```hcl
module "state_bucket" {
  source = "./modules/s3-state"
}
```

Rationale: At initial scale, the overhead of separate module repos (semantic versioning,
registry publishing, coordinated cross-repo PRs for a single change) outweighs the benefits.
All three modules change together with the platform configuration. A single PR can update
a module and its consuming call in one diff, making review straightforward and eliminating
version pin drift.

Deferred items with explicit placeholder comments in code:

- Cross-region S3 replication (`terraform/modules/s3-state/main.tf`) — ADR-001 / ADR-003
- Multi-account AWS via AWS Organizations (`terraform/main.tf`)
- Azure provider (`terraform/main.tf`)
- GitLab provider (`terraform/main.tf`)
- Module extraction to own repos (this ADR, Future State)

## Consequences

- All module changes in one PR — no cross-repo coordination needed.
- No version management overhead at this stage — no registry, no version pins to update.
- Module source paths use relative references, which work correctly with `terraform -chdir`.
- If modules are later extracted, every `source =` reference in `terraform/main.tf` will
  need updating to a registry path or absolute URL. This is a mechanical find-and-replace,
  not a logic change.
- The module structure is already clean (inputs via `variables.tf`, outputs via `outputs.tf`,
  tests in `tests/`), so extraction is a refactor not a redesign when the time comes.

## Alternatives Considered

- **Separate module repos from day one:** Premature at this scale. Adds versioning friction,
  requires coordinated PRs across multiple repositories for any change that spans a module
  and its consumer. The benefit (independent versioning for other teams) does not exist yet
  because there are no other consumers.
- **Terraform Registry (public):** Appropriate for open-source modules intended for public
  consumption. Inappropriate for private platform configuration that contains org-specific
  conventions and naming patterns.

## Future State

When modules stabilize and are consumed by other teams or repositories, extract each module
to its own versioned repository and publish to a private Terraform registry (or GitHub
releases). The trigger condition is: a module is needed by a team that does not have write
access to platform-bootstrap.

Until that trigger is met, in-repo modules remain the correct tradeoff.
