# ADR-002: OIDC Authentication for GitHub Actions to AWS (No Static Credentials)

**Status:** Accepted
**Date:** 2025-05-22
**Deciders:** @MichaelHeaton

## Context

GitHub Actions pipelines need to authenticate to AWS to read and write Terraform state and
manage infrastructure resources. The traditional approach is IAM users with static access keys
stored as GitHub Secrets. Static credentials carry well-known risks: they do not expire, they
can be accidentally committed, they require manual rotation, and a leaked key provides
persistent access until it is explicitly revoked.

## Decision

Use OpenID Connect (OIDC) federation between GitHub Actions and AWS. Each pipeline assumes an
IAM role via a short-lived web identity token issued by GitHub for each job run. No static AWS
credentials exist anywhere in the repository or GitHub Secrets.

The OIDC provider resource (`aws_iam_openid_connect_provider`) is managed in the `oidc-roles`
module. Trust conditions on each IAM role restrict assumption to a specific GitHub repository
and a specific set of Git refs (`allowed_refs`). The audience is locked to `sts.amazonaws.com`.

Example trust condition for `repo:my-org/my-repo:refs/heads/main`:

```hcl
Condition = {
  StringEquals = {
    "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
  }
  StringLike = {
    "token.actions.githubusercontent.com:sub" = [
      "repo:my-org/my-repo:refs/heads/main"
    ]
  }
}
```

## Consequences

- No credentials to rotate, leak, or expire. The attack surface for credential compromise is
  eliminated.
- Token lifetime is bounded by the GitHub Actions job lifetime (typically minutes).
- The trust relationship is enforced by GitHub's OIDC token claims: `repo`, `ref`, and `aud`.
  A workflow in a different repository, or on a different branch, cannot assume the role even
  if it knows the role ARN.
- Every `sts:AssumeRoleWithWebIdentity` call appears in AWS CloudTrail, linked to the specific
  workflow run ID via the token claims.
- Initial setup is slightly more complex than storing a secret: an OIDC provider resource must
  exist in the AWS account before any workflow can authenticate. This is handled by
  `terraform apply` during bootstrap — see `docs/runbooks/02-bootstrap.md`.
- GitHub thumbprints for the OIDC CA must be kept current. Both primary and secondary
  thumbprints are listed in `terraform/modules/oidc-roles/main.tf` with a comment explaining
  the rotation context.

## Alternatives Considered

- **IAM users with access keys stored as GitHub Secrets:** Keys can be accidentally committed,
  are long-lived, require periodic rotation, and provide persistent access if stolen. Rejected
  for all non-bootstrap use.
- **AWS Secrets Manager with key rotation:** Still requires a bootstrap credential to retrieve
  the initial secret. Adds complexity without eliminating the root problem.
- **Self-hosted GitHub Actions runners with EC2 instance profiles:** Avoids the key problem
  entirely but adds significant operational overhead: runner fleet management, patching, and
  cost. Not warranted at this scale.

## Future State

If Azure workloads are added, a separate OIDC provider for Microsoft Entra ID will be
required. The module structure is designed to accommodate additional providers as new
`aws_iam_openid_connect_provider` resources.

Multi-account role chaining (assume a role in one account that cross-account-assumes a role in
another) will be required if AWS Organizations is adopted. This is deferred — see ADR-006.
