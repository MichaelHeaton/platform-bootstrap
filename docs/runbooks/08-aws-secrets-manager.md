# Runbook 08 — AWS Secrets Manager (stored secrets)

**Estimated time:** ~15 minutes (initial upload) / ~5 minutes (rotation)

---

## 1. Overview

Long-lived secrets that cannot be replaced by OIDC or short-lived tokens live in **AWS Secrets
Manager** in the platform AWS account (`336090301942`, `us-west-2`).

Naming convention:

```text
{scope}/{purpose}
```

| Scope | Use |
|---|---|
| `platform-bootstrap/` | Secrets consumed by this repo's Terraform or HCP runs |
| `personal/` | Workstation / MCP integration tokens (same account, separate IAM path) |

> **Credential strategy:** see `AGENTS.md`. Prefer ephemeral and short-lived credentials first;
> use SM only for secrets that must persist overnight.

---

## 2. Current secret inventory

| Secret name | Purpose | Consumed by |
|---|---|---|
| `platform-bootstrap/github-app-pem` | GitHub App private key (app `3977205`) | HCP Terraform today (via HCP variable); SM is canonical store — Terraform SM read pending (#51) |
| `personal/linear-api-token` | Linear API token (MCP / automation) | Workstation — not wired in this repo yet |
| `personal/notion-api-token` | Notion integration token (MCP / automation) | Workstation — not wired in this repo yet |
| `personal/cloudflare-api-token` | Cloudflare API token `platform-terraform-dns` — DNS Edit + Zone Read on 5 zones | `cloudflare` repo (HCP/GHA) via OIDC + SM read — see runbook 09 |

Verify all four exist:

```bash
export AWS_PROFILE=platform-bootstrap
export AWS_REGION=us-west-2

aws secretsmanager describe-secret --secret-id platform-bootstrap/github-app-pem --query Name --output text
aws secretsmanager describe-secret --secret-id personal/linear-api-token --query Name --output text
aws secretsmanager describe-secret --secret-id personal/notion-api-token --query Name --output text
aws secretsmanager describe-secret --secret-id personal/cloudflare-api-token --query Name --output text
```

Check PEM length without printing the value:

```bash
aws secretsmanager get-secret-value \
  --secret-id platform-bootstrap/github-app-pem \
  --query 'length(SecretString)' \
  --output text
# Expect ~1678 for a 2048-bit RSA key
```

---

## 3. Upload secrets (CLI)

Use profile `platform-bootstrap` and region `us-west-2`.

### GitHub App private key (PEM)

macOS often blocks Terminal from reading `~/Downloads` (`Operation not permitted`). Copy the PEM
to a controlled path first (Finder drag is fine):

```bash
mkdir -p ~/.config/platform-bootstrap
# Move github-app.pem here via Finder if cp from Downloads fails
chmod 600 ~/.config/platform-bootstrap/github-app.pem
```

Create or update:

```bash
export AWS_PROFILE=platform-bootstrap
export AWS_REGION=us-west-2
PEM_FILE="$HOME/.config/platform-bootstrap/github-app.pem"

aws secretsmanager create-secret \
  --name platform-bootstrap/github-app-pem \
  --description "GitHub App private key for platform-bootstrap-terraform" \
  --secret-string "$(cat "$PEM_FILE")"
```

If the secret already exists:

```bash
aws secretsmanager put-secret-value \
  --secret-id platform-bootstrap/github-app-pem \
  --secret-string "$(cat "$PEM_FILE")"
```

See [07-github-app-auth.md](./07-github-app-auth.md) for App creation and HCP installation IDs.

### Linear API token

```bash
read -s "?Linear API key: " LINEAR_API_KEY; echo

aws secretsmanager create-secret \
  --name personal/linear-api-token \
  --description "Linear API token" \
  --secret-string "$LINEAR_API_KEY"

unset LINEAR_API_KEY
```

Use `put-secret-value` instead of `create-secret` if updating an existing secret.

### Notion integration token

Notion may not be configured on every workstation. Get the token from
[notion.so/my-integrations](https://www.notion.so/my-integrations) → your integration →
**Internal Integration Secret**, then:

```bash
read -s "?Notion integration token: " NOTION_API_TOKEN; echo

aws secretsmanager create-secret \
  --name personal/notion-api-token \
  --description "Notion integration API token" \
  --secret-string "$NOTION_API_TOKEN"

unset NOTION_API_TOKEN
```

### Cloudflare API token (`platform-terraform-dns`)

Create a **custom** token at [dash.cloudflare.com/profile/api-tokens](https://dash.cloudflare.com/profile/api-tokens) — not “Read all resources”.

| Setting | Value |
|---|---|
| Token name | `platform-terraform-dns` |
| Permissions | Zone → DNS → **Edit**; Zone → Zone → **Read** |
| Zone resources | Include → specific zones: `heatons.me`, `mccleaton.com`, `specterrealm.com`, `spicyaccountants.fun`, `the-blackhole.com` |

Copy the token immediately — Cloudflare shows it only once.

```bash
read -s "?Cloudflare API token: " CLOUDFLARE_API_TOKEN; echo

aws secretsmanager create-secret \
  --name personal/cloudflare-api-token \
  --description "Cloudflare API token" \
  --secret-string "$CLOUDFLARE_API_TOKEN"

unset CLOUDFLARE_API_TOKEN
```

Verify without printing the value:

```bash
aws secretsmanager get-secret-value \
  --secret-id personal/cloudflare-api-token \
  --query 'length(SecretString)' \
  --output text
# Expect ~40 for a typical API token
```

Optional smoke test (requires `curl` and a zone you manage):

```bash
export CLOUDFLARE_API_TOKEN="$(aws secretsmanager get-secret-value \
  --secret-id personal/cloudflare-api-token \
  --query SecretString --output text)"

curl -s -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  https://api.cloudflare.com/client/v4/user/tokens/verify
# Expect 200

unset CLOUDFLARE_API_TOKEN
```

Use `put-secret-value` instead of `create-secret` if updating an existing secret.

#### Optional: additional Cloudflare tokens (later)

The DNS token above is enough for the `cloudflare` Terraform repo. Add separate tokens only
when a spoke repo needs capabilities DNS cannot provide:

| Token purpose | Permissions (typical) | Unlocks |
|---|---|---|
| **Tunnel** (`platform-terraform-tunnel`) | Account → Cloudflare Tunnel → Edit; Account → Account Settings → Read | Terraform for `cloudflared` tunnels, ingress routes, Zero Trust connectors — homelab remote access without open ports |
| **R2** (`platform-terraform-r2`) | Account → Workers R2 Storage → Edit | Terraform for R2 buckets, lifecycle rules, CORS — Memex file storage, static assets with no egress fees |

Store each as its own SM secret (e.g. `personal/cloudflare-tunnel-api-token`) with a dedicated
IAM grant on the consuming pipeline role. Do not widen the DNS token.

---

## 4. HCP Terraform and SM (transitional)

Today, HCP still passes the GitHub App PEM via workspace variable `github_app_pem` (terraform
category). SM holds the **canonical copy**; HCP holds the **runtime copy** until Terraform reads
SM directly ([#51](https://github.com/MichaelHeaton/platform-bootstrap/issues/51)).

| Variable | Still in HCP? | Notes |
|---|---|---|
| `github_app_id` | Yes | Not secret — stays in HCP |
| `github_app_installation_id` | Yes | Not secret |
| `specterrealm_github_app_installation_id` | Yes | Not secret |
| `github_app_pem` | Yes (for now) | Remove from HCP after Terraform reads SM |

When rotating the App private key: update **both** SM and HCP until the SM data source is merged.

---

## 5. IAM access (future)

The HCP dynamic credentials role `platform-bootstrap-tfe` will need scoped read access before
Terraform can read SM at plan time:

```text
secretsmanager:GetSecretValue  on  arn:aws:secretsmanager:us-west-2:336090301942:secret:platform-bootstrap/*
```

Workstation users use the `platform-bootstrap` AWS profile with broader SM access for manual
uploads. Do not grant `platform-bootstrap/*` read to unrelated spoke workspaces.

Spoke pipeline roles (e.g. `shared-cloudflare-dns-github-actions`) receive scoped
`secretsmanager:GetSecretValue` via their `*-state-access` IAM policy when listed in the
pipeline entry — see [09-cloudflare-terraform-repo.md](./09-cloudflare-terraform-repo.md).

---

## 6. Rotation

| Secret | How to rotate |
|---|---|
| `platform-bootstrap/github-app-pem` | GitHub App → Generate new private key → `put-secret-value` in SM → update HCP `github_app_pem` → delete old key in GitHub |
| `personal/linear-api-token` | Linear settings → new token → `put-secret-value` → update MCP env |
| `personal/notion-api-token` | Notion integration → refresh secret → `put-secret-value` → update MCP env |
| `personal/cloudflare-api-token` | Cloudflare dashboard → roll token → `put-secret-value` → update spoke repos / env |

Never commit secret values to git or paste them into PR descriptions.

---

## 7. Cleanup after upload

- Delete local PEM from `~/Downloads` and `~/.config/platform-bootstrap/` once SM is verified
- Legacy fine-grained PATs (`tfe_pb_*`) and HCP PAT variables should already be removed — see
  [06-rotate-github-pats.md](./06-rotate-github-pats.md) (deprecated) and
  [07-github-app-auth.md](./07-github-app-auth.md)

---

## 8. Related

- [07 — GitHub App authentication](./07-github-app-auth.md)
- [09 — Cloudflare Terraform repo](./09-cloudflare-terraform-repo.md)
- [Issue #51 — Migrate secrets to AWS Secrets Manager](https://github.com/MichaelHeaton/platform-bootstrap/issues/51)
- `AGENTS.md` — credential tier strategy
