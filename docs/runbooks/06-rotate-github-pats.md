# Runbook 06 — Rotate GitHub Fine-Grained PATs (deprecated)

> **Superseded by runbooks 07 and 08.** platform-bootstrap now uses a GitHub App with
> short-lived installation tokens instead of fine-grained PATs. Stored secrets live in AWS
> Secrets Manager. See [07-github-app-auth.md](./07-github-app-auth.md) and
> [08-aws-secrets-manager.md](./08-aws-secrets-manager.md).

Remove legacy HCP variables after GitHub App auth is verified:

- `tfe_pb_michaelheaton`
- `tfe_pb_specterrealm`
- `tfe_pb_specterrealm_homelab`

Revoke the corresponding fine-grained PATs in GitHub once HCP plans succeed with App auth.
