# Runbook 07 — GitHub App authentication for Terraform

**Estimated time:** ~30 minutes (one-time setup)

---

## 1. Overview

platform-bootstrap uses a **GitHub App** (not user PATs) for Terraform's GitHub providers.
The provider mints **short-lived installation access tokens** (~1 hour) at plan/apply time.

Benefits over PATs:

- No 30/60/90-day expiry cycle to babysit
- Narrow, auditable permissions on the App
- Same App installed on `MichaelHeaton`, **`McCleaton`**, and `SpecterRealm` with separate installation IDs
- `specterrealm-homelab` is installed on the App for future use; no Terraform provider until homelab repos are managed here

---

## 2. Create the GitHub App

1. Go to **GitHub → Settings → Developer settings → GitHub Apps → New GitHub App**
   (or org settings for SpecterRealm if you prefer org-owned app — user-owned works for both)
2. Suggested name: `platform-bootstrap-terraform`
3. Homepage URL: `https://github.com/MichaelHeaton/platform-bootstrap`
4. **Uncheck** "Webhook → Active" (not needed)
5. Permissions — set **Repository permissions**:

   | Permission | Access | Why |
   |---|---|---|
   | Administration | Read and write | Create repos, branch protection, rulesets, Pages |
   | Contents | Read and write | CODEOWNERS, LICENSE commits via local-exec |
   | Issues | Read and write | Managed labels |
   | Metadata | Read | Required baseline |
   | Pages | Read and write | `github_repository_pages` on pack repos |
   | Secrets | Read and write | `github_actions_secret` on service repos |
   | Variables | Read and write | `github_actions_variable` on service repos |

6. Permissions — set **Organization permissions** (for org installs — McCleaton, SpecterRealm):

   | Permission | Access | Why |
   |---|---|---|
   | Administration | Read and write | Create/manage org repositories |

7. **Where can this GitHub App be installed?** → "Any account" (or restrict to your accounts)
8. Create the app
9. Note the **App ID** (shown at top of app settings)
10. **Generate a private key** → download the `.pem` file (store securely; rotate by generating a new key if compromised)

---

## 3. Install the App

Install the same app on **both** required targets (homelab install is optional until those repos are managed here):

### MichaelHeaton (user account)

1. App settings → **Install App** → your user account
2. Repository access: **All repositories** (or select subset if you prefer least scope)
3. Note the **Installation ID** from the URL:
   `https://github.com/settings/installations/<INSTALLATION_ID>`

> **Personal account limitation:** GitHub App installation tokens can manage existing
> repos on your user account but **cannot create new ones** (`POST /user/repos` requires a
> user token). **Register new infrastructure spokes under the McCleaton org**
> (`mccleaton_repositories`) where the App uses `POST /orgs/{org}/repos`. SpecterRealm is
> reserved for Minecraft/modpack content only.

### McCleaton (organization — platform infrastructure)

Create the org first — see [09-cloudflare-terraform-repo.md](./09-cloudflare-terraform-repo.md) step 0.

1. Install App → **McCleaton** org
2. Repository access: **All repositories**
3. Note the **Installation ID** from:
   `https://github.com/organizations/McCleaton/settings/installations/<INSTALLATION_ID>`

### SpecterRealm (organization — Minecraft / modpacks)

1. Install App → **SpecterRealm** org
2. Repository access: **All repositories**
3. Note the **Installation ID** from:
   `https://github.com/organizations/SpecterRealm/settings/installations/<INSTALLATION_ID>`

### specterrealm-homelab (organization) — optional, future

Install the App here when homelab repos are added to Terraform. Installation ID `138340201`
(documented for later; no HCP variable required until the provider is wired in code).

---

## 4. Configure HCP Terraform workspace variables

In the `McCleaton-Bootstrap/platform-bootstrap` workspace, **remove** legacy sensitive variables:

- `tfe_pb_michaelheaton` (legacy PAT)
- `tfe_pb_specterrealm` (legacy PAT)
- `tfe_pb_specterrealm_homelab` (legacy PAT)

Add these workspace variables (category **terraform**, not env):

| Variable | Sensitive? | Value |
|---|---|---|
| `github_app_id` | No | App ID from step 2 |
| `github_app_installation_id` | No | Installation ID on MichaelHeaton |
| `mccleaton_github_app_installation_id` | No | Installation ID on McCleaton (platform infra org) |
| `specterrealm_github_app_installation_id` | No | Installation ID on SpecterRealm (Minecraft/modpacks) |
| `tfe_vcs_oauth_token_id` | No | OAuth token ID from HCP Organization Settings → VCS Providers (McCleaton GitHub) |

> **Secrets Manager:** long-lived secrets are read from SM at plan time — see
> [08-aws-secrets-manager.md](./08-aws-secrets-manager.md).
> - `platform-bootstrap/github-app-pem` — GitHub App private key (not an HCP variable)
> - `platform-bootstrap/tfe-api-token` — HCP org API token (not an HCP variable)
> - `platform-bootstrap/tfe-api-token` — org-level HCP API token; Terraform reads SM at
>   plan time (no HCP variable).

Example PEM format for HCP (single line):

```text
-----BEGIN RSA PRIVATE KEY-----\nMIIE...\n-----END RSA PRIVATE KEY-----\n
```

---

## 5. Local development

Export installation IDs and other non-secret vars. PEM and HCP org token come from SM:

```bash
export TF_VAR_github_app_id="123456"
export TF_VAR_github_app_installation_id="7890123"
export TF_VAR_specterrealm_github_app_installation_id="4567890"
export TF_VAR_mccleaton_github_app_installation_id="..."
# Local shell uses TF_VAR_ prefix; HCP workspace UI uses bare names (terraform category).
export TF_VAR_github_org="MichaelHeaton"
# ... other TF_VAR_* from runbook 02
```

Run plan/apply from `terraform/` with AWS credentials (`AWS_PROFILE=platform-bootstrap`) so
Terraform can read `platform-bootstrap/github-app-pem` and `platform-bootstrap/tfe-api-token`
from SM.

---

## 6. Verify

After merging the GitHub App auth Terraform changes:

1. Trigger a plan in HCP (push to a branch or queue plan manually)
2. Confirm no `403 Resource not accessible by integration` errors
3. Confirm managed repos plan cleanly (no PAT-related variable errors)

If you see 403 errors, check:

| Symptom | Fix |
|---|---|
| `POST /user/repos` on personal account | Register new infra repo under **McCleaton** (`mccleaton_repositories`), not personal account |
| Org repo create 403 | App missing org **Administration** write, or pending permission approval on installation |
| Other 403 | `owner` set on provider; installation ID matches target; accept pending permission requests |

Also verify:

- `owner` is set on each provider (`MichaelHeaton` / `SpecterRealm`)
- Installation ID matches the account/org being managed
- App permissions include **Pages**, **Secrets**, and **Variables** (all read/write on repositories)
- After changing App permissions, open each installation → **Review pending request** → Accept

---

## 7. Key rotation

| Asset | Rotation |
|---|---|
| App private key | Generate new key in GitHub App settings → `put-secret-value` in SM (`platform-bootstrap/github-app-pem`) → delete old key in GitHub |
| Installation | Re-install app if permissions change; installation ID usually stays the same |
| App ID | Never changes unless you create a new app |

Full SM procedures: [08-aws-secrets-manager.md](./08-aws-secrets-manager.md).

---

## 8. Compliance workflow note

`scripts/compliance_check.py` full mode still uses `GITHUB_TOKEN` from the environment
(GitHub Actions `GITHUB_TOKEN` or a PAT for local runs). That workflow is separate from
Terraform provider auth and is unchanged by this runbook.
