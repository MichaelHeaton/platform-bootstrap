# ADR-008: GitHub repository baseline settings for Iris

**Status:** Accepted
**Date:** 2026-10-05
**Deciders:** @MichaelHeaton

## Context

Iris is a personal AI assistant suite (web UI, API, MCP server; knowledge, relationships,
tickets, calendar, later voice) built as modular microservices in one monorepo. The suite
starts as a personal/family tool and may become a product later. Repository creation and
settings for platform-managed GitHub repos already live in `terraform/modules/github-repos`
(ADR-004). Iris needs a stricter baseline than the module’s historical defaults, without
changing settings on existing repositories.

Constraints from the platform:

- GitHub App installation tokens can manage repositories on the `MichaelHeaton` user account
  but cannot create new ones (`POST /user/repos` requires a user token). See runbook 07.
- McCleaton and SpecterRealm orgs are being retired; new personal work stays on
  `MichaelHeaton`.
- Iris secrets will live in HashiCorp Vault in the homelab — this ADR does not create cloud
  secret stores, Vault, Authentik, or AWS resources for Iris.

## Decision

1. **Register exactly one repo:** `MichaelHeaton/iris` (private) in `managed_repositories`,
   with description and topics as specified for the Iris monorepo. No sibling repos for
   Memex, tickets, or other modules — those live inside `iris` later.

2. **Personal-account create/import exception:** Because the App cannot create user-owned
   repos, create an empty private `iris` once with a user-authenticated `gh` session, then
   adopt it with an OpenTofu `import` block into
   `module.github_repos.github_repository.managed["iris"]`. After import, Terraform owns
   settings; do not use imperative settings changes. This is the only approved exception to
   AGENTS.md’s “never create repos imperatively” rule, and only for user-account bootstraps
   where App create is impossible.

3. **Opt-in module knobs** (defaults preserve legacy behavior for all other repos):

   | Knob | Iris value | Effect |
   |---|---|---|
   | `squash_merge_only` | true | Merge commits and rebase merges disabled |
   | `require_signed_commits` | true | SSH-signed commits required on `main` |
   | `require_linear_history` | true | Linear history required |
   | `require_conversation_resolution` | true | Conversations must be resolved |
   | `enforce_admins` | true | No admin bypass of protection |
   | `codeowners_file` | `.github/CODEOWNERS` | CODEOWNERS under `.github/` |
   | `dependabot_security_updates` | true | Dependabot security updates on |
   | `actions_hardened` | true | Selected actions (GitHub-owned + verified); workflow token read-only; Actions cannot approve PRs |

   Branch protection still requires a PR with **0** approving reviews (sole maintainer cannot
   approve own PRs). Force pushes and deletions remain blocked. Required status checks stay
   unset until CI exists (tracked in-repo).

4. **Iris labels** are defined in `terraform/iris.tf` and merged via
   `managed_repositories_resolved`: `type/*`, `area/*`, `priority/p0`–`p3`,
   `status/needs-decision`.

5. **No license file** while private; rights reserved until an explicit license decision.

## Unavailable on private personal repos (do not silently enable)

Probed 2026-10-05 against `MichaelHeaton` private repos:

- **Secret scanning / push protection:** API returns 422 (“not available for this repository”)
  without GitHub Advanced Security / public visibility.
- **Private vulnerability reporting:** REST endpoint not found for this account.
- **Code scanning default setup:** not available until code scanning is enabled (GHAS or
  public).

These stay **off** in Terraform for Iris. Track enabling them when the repo goes public or
GHAS is purchased — do not fake compliance by omitting them from the expected checklist.

## Signed commits vs automation

`require_signed_commits` is intentional and must not be disabled for agent convenience.
Bootstrap commits (README + CODEOWNERS) run **before** branch protection is applied.
Afterwards, App/`local-exec` and unsigned agent commits cannot land on `main`; use signed
commits or a signed merge from `@MichaelHeaton`. A future self-hosted PR-Agent / second
reviewer identity is expected to ratchet approvals (in-repo tracking issue).

## Consequences

- Adding Iris is a PR to platform-bootstrap; apply runs in CI, not from a laptop.
- Existing managed repos keep current merge, protection, CODEOWNERS path, and Actions
  settings unless they opt into the new knobs.
- Memex vault (`MichaelHeaton/memex`) and `memex-suite` remain separate; Iris does not
  replace them in this change.

## Alternatives considered

- **SpecterRealm or McCleaton hosting:** Rejected — orgs are being retired; SpecterRealm is
  Minecraft-only by convention; private protection on free org plans is a risk.
- **App-only create with no import:** Impossible on the user account.
- **Changing module defaults globally:** Would alter every managed repo; rejected in favor of
  opt-in knobs.
