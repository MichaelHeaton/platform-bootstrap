# Runbook 06 — Rotate GitHub Fine-Grained PATs

**Estimated time:** ~15 minutes per token

---

## 1. Overview

platform-bootstrap uses three fine-grained GitHub PATs to authenticate the Terraform GitHub
provider for each org it manages. These tokens are stored as sensitive workspace variables in
HCP Terraform (`McCleaton-Bootstrap / platform-bootstrap`).

| Token name | GitHub org | HCP variable | Expires |
|---|---|---|---|
| `tfe-pb-michaelheaton` | `MichaelHeaton` | `github_token` | ⚠️ No expiry — set one |
| `tfe-pb-specterrealm` | `SpecterRealm` | `specterrealm_github_token` | Jun 4 2027 |
| `tfe-pb-specterrealm-homelab` | `specterrealm-homelab` | `specterrealm_homelab_github_token` | Jun 4 2027 |

---

## 2. Required PAT Permissions

Each token must be scoped to **All repositories** in its org with these permissions:

| Permission | Level |
|---|---|
| Administration | Read and write |
| Contents | Read and write |
| Issues | Read and write |
| Metadata | Read-only |
| Members | Read-only |
| Pages | Read and write |
| Pull requests | Read and write |
| Secrets | Read and write |
| Variables | Read and write |

---

## 3. Rotation Steps

### 3.1 Generate the new token

1. Go to **GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens**
2. Find the token to rotate and click it
3. Click **Regenerate token** (or **Generate new token** if recreating)
4. Set expiry to **1 year** from today
5. Confirm all permissions match the table above
6. Copy the new token value immediately — it is only shown once

Save the token temporarily in Apple Keychain before proceeding.

### 3.2 Update the HCP Terraform workspace variable

1. Go to **app.terraform.io → McCleaton-Bootstrap → platform-bootstrap → Variables**
2. Find the corresponding variable (e.g. `github_token`)
3. Click **⋯ → Edit**
4. Paste the new token value
5. Ensure **Sensitive** is checked and **HCL is unchecked**
6. Click **Save variable**

### 3.3 Trigger a plan to verify

1. In HCP Terraform, click **+ New run → Plan only**
2. Confirm the plan completes without authentication errors or rate limit warnings
3. Discard the run — no apply needed (no infrastructure changes)

### 3.4 Clean up

- Delete the old token value from Apple Keychain
- Update the expiry date in the Notion **Platform Accounts** database for that org

---

## 4. If a Token Has Already Expired

If a run fails with `401 Bad credentials` or `403 Resource not accessible`:

1. Follow steps 3.1–3.3 above to generate and apply a new token
2. Re-run the failed plan from the HCP Terraform UI
3. If the plan was triggered by a PR merge, manually trigger a new run from the workspace

---

## 5. Notes

- Tokens are org-scoped — rotating one does not affect the others
- The `github_token` (MichaelHeaton) has no expiration date — set one on next rotation
- Never commit token values to the repository or paste them into PR descriptions
