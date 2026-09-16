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
| `platform-bootstrap/github-app-pem` | GitHub App private key (app `3977205`) | `platform-bootstrap` Terraform via SM at plan time |
| `platform-bootstrap/tfe-api-token` | HCP org API token (workspace factory + `tfe` provider) | `platform-bootstrap` Terraform reads SM at plan time; fans out to spoke `TF_TOKEN_app_terraform_io` |
| `personal/linear-api-token` | Linear API token (MCP / automation) | Workstation — not wired in this repo yet |
| `personal/notion-api-token` | Notion integration token (MCP / automation) | Workstation — not wired in this repo yet |
| `personal/cloudflare-api-token` | Cloudflare API token `platform-terraform-dns` — DNS Edit + Zone Read on 5 zones | `homelab-infra/terraform/cloudflare` (mail/DNS) via pipeline SM grant — keep DNS-only |
| `platform-bootstrap/cloudflare-api-token` | Tunnel substrate token: Zone DNS Edit + Zone Read on `specterrealm.com` **and** Account → Cloudflare Tunnel → Edit | `terraform/cloudflare-tunnel.tf` (kb-mcp CNAME + remote ingress, #1135) — see § Tunnel substrate |
| `personal/curseforge-api-key` | CurseForge legacy upload API key (`X-Api-Token`) | GHA OIDC on `minecraft-modpack-cp-verdant` + `specterrealm-core`; workstation `make upload-cf` |
| `personal/slack-bot-token` | SpecterRealm Slack bot (`xoxb-…`) — workspace `specterrealmworkspace` | homelab n8n (planned); workstation MCP — see runbook 10 |
| `personal/discord-bot-token` | Discord bot token (optional) | homelab n8n / family bots — see runbook 10 |
| `personal/discord-webhook-url` | Discord channel webhook (one-way alerts) | homelab n8n (planned) — see runbook 10 |

Verify platform secrets exist (comms secrets optional until uploaded):

```bash
aws secretsmanager describe-secret --secret-id personal/slack-bot-token --query Name --output text 2>/dev/null || echo "personal/slack-bot-token — not yet uploaded"
aws secretsmanager describe-secret --secret-id personal/discord-webhook-url --query Name --output text 2>/dev/null || echo "personal/discord-webhook-url — not yet uploaded"
```

Verify core six exist:

```bash
export AWS_PROFILE=platform-bootstrap
export AWS_REGION=us-west-2

aws secretsmanager describe-secret --secret-id platform-bootstrap/github-app-pem --query Name --output text
aws secretsmanager describe-secret --secret-id platform-bootstrap/tfe-api-token --query Name --output text
aws secretsmanager describe-secret --secret-id personal/linear-api-token --query Name --output text
aws secretsmanager describe-secret --secret-id personal/notion-api-token --query Name --output text
aws secretsmanager describe-secret --secret-id personal/cloudflare-api-token --query Name --output text
aws secretsmanager describe-secret --secret-id personal/curseforge-api-key --query Name --output text
aws secretsmanager describe-secret --secret-id platform-bootstrap/cloudflare-api-token --query Name --output text 2>/dev/null \
  || echo "platform-bootstrap/cloudflare-api-token — seed for Tunnel substrate (homelab-infra #1135)"
```

### Tunnel substrate SM token (kb-mcp / homelab-infra #1135)

Public Tunnel **DNS CNAME** and **remote ingress** are applied from **this** repo
(`terraform/cloudflare-tunnel.tf`). Ingress uses
`cloudflare_zero_trust_tunnel_cloudflared_config` (hostname → in-cluster service +
catch-all 404) and does **not** create a second DNS record — the TF CNAME stays
authoritative.

The `platform-bootstrap-github-actions` role only reads `platform-bootstrap/*`.
**Do not** widen `personal/cloudflare-api-token` (mail/DNS stays DNS-only). Instead
seed a substrate token under `platform-bootstrap/cloudflare-api-token` with both
DNS and Tunnel scopes.

#### One-time: create or rotate the substrate token

At [dash.cloudflare.com/profile/api-tokens](https://dash.cloudflare.com/profile/api-tokens)
create a **custom** token (or edit the existing substrate token):

| Setting | Value |
|---|---|
| Token name | `platform-terraform-tunnel-substrate` (or reuse prior substrate name) |
| Permissions | Zone → DNS → **Edit**; Zone → Zone → **Read**; Account → **Cloudflare Tunnel** → **Edit** |
| Zone resources | Include → Specific zone → `specterrealm.com` |
| Account resources | Include → the account that owns the `kb-mcp` tunnel |

DNS Edit alone is enough for the CNAME; **Tunnel Edit is required** for remote
ingress config. Without Tunnel Edit, gated apply fails on
`cloudflare_zero_trust_tunnel_cloudflared_config.kb_mcp`.

```bash
export AWS_PROFILE=platform-bootstrap AWS_REGION=us-west-2
read -s "?Cloudflare Tunnel substrate API token: " CF_TUNNEL_TOKEN; echo
if aws secretsmanager describe-secret --secret-id platform-bootstrap/cloudflare-api-token >/dev/null 2>&1; then
  aws secretsmanager put-secret-value \
    --secret-id platform-bootstrap/cloudflare-api-token \
    --secret-string "${CF_TUNNEL_TOKEN}"
else
  aws secretsmanager create-secret \
    --name platform-bootstrap/cloudflare-api-token \
    --description "Cloudflare DNS+Tunnel token for kb-mcp substrate (not a copy of personal/ DNS-only)" \
    --secret-string "${CF_TUNNEL_TOKEN}"
fi
unset CF_TUNNEL_TOKEN
```

Bootstrap shortcut (DNS-only, **insufficient for ingress**): you may still copy
`personal/cloudflare-api-token` into `platform-bootstrap/cloudflare-api-token` to
create the CNAME first. Before applying tunnel config, replace that value with a
token that includes Account → Cloudflare Tunnel → Edit (commands above).

#### Symptom: gated apply 403 / Authentication error (code 10000)

```
PUT .../cfd_tunnel/<uuid>/configurations: 403 Forbidden
{"errors":[{"code":10000,"message":"Authentication error"}]}
```

on `cloudflare_zero_trust_tunnel_cloudflared_config.kb_mcp` means the SM value is
still DNS-only (or Account resources omit the tunnel’s account). CNAME create can
succeed; ingress PUT cannot. Rotate with the commands above, then re-run
**OpenTofu Apply (gated)**. CI also runs
`scripts/ci-cloudflare-tunnel-token-prereq.sh` before apply so this fails closed
with the same instructions.

After Zero Trust tunnel create, set GitHub Actions variable
`TF_VAR_kb_mcp_tunnel_id=<tunnel-uuid>` on **platform-bootstrap** (or use
`terraform/kb_mcp.auto.tfvars`). Empty UUID keeps the public CNAME and ingress
absent on purpose.

Apply path: merge PR → Actions → **OpenTofu Apply (gated)** on `main` with
`confirm_apply=yes` → approve Environment `opentofu-apply`. No laptop curl.

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

### HCP org API token (`tfe-api-token`)

Create at [app.terraform.io](https://app.terraform.io) → User settings → **Tokens** (org-level
token with permission to manage workspaces in `McCleaton-Bootstrap`).

```bash
read -s "?HCP org API token: " TFE_API_TOKEN; echo

aws secretsmanager create-secret \
  --name platform-bootstrap/tfe-api-token \
  --description "HCP org API token for platform-bootstrap workspace factory" \
  --secret-string "$TFE_API_TOKEN"

unset TFE_API_TOKEN
```

If the secret already exists:

```bash
aws secretsmanager put-secret-value \
  --secret-id platform-bootstrap/tfe-api-token \
  --secret-string "$TFE_API_TOKEN"
```

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

### CurseForge API key

Create or copy at [CurseForge Authors → API Tokens](https://authors.curseforge.com/#/settings/api-tokens). One token can upload to both Colony Protocol: Verdant (modpack) and SpecterRealm Core (mod).

```bash
read -s "?CurseForge API key: " CURSEFORGE_API_KEY; echo

aws secretsmanager create-secret \
  --name personal/curseforge-api-key \
  --description "CurseForge legacy upload API key" \
  --secret-string "$CURSEFORGE_API_KEY"

unset CURSEFORGE_API_KEY
```

Use `put-secret-value` instead of `create-secret` if updating an existing secret.

Verify without printing the value:

```bash
aws secretsmanager get-secret-value \
  --secret-id personal/curseforge-api-key \
  --query 'length(SecretString)' \
  --output text
```

**CI:** After uploading the secret, apply `platform-bootstrap` Terraform (pipelines in `managed.auto.tfvars`). That creates OIDC roles and sets `AWS_CURSEFORGE_UPLOAD_ROLE_ARN` on each release repo. Workflows fetch the key at runtime — do **not** store it as a GitHub secret.

**Workstation:**

```bash
export AWS_PROFILE=platform-bootstrap AWS_REGION=us-west-2
export CURSEFORGE_API_KEY="$(aws secretsmanager get-secret-value \
  --secret-id personal/curseforge-api-key \
  --query SecretString --output text)"
make upload-cf   # minecraft-modpack-cp-verdant
```

#### Optional: additional Cloudflare tokens (later)

Keep `personal/cloudflare-api-token` DNS-only (mail/DNS in `homelab-infra`). Tunnel
**remote ingress** for kb-mcp uses the separate substrate secret
`platform-bootstrap/cloudflare-api-token` (DNS + Tunnel Edit) — see § Tunnel substrate
above. Add further tokens only when a consumer needs capabilities those do not provide:

| Token purpose | Permissions (typical) | Unlocks |
|---|---|---|
| **Tunnel create** (`platform-terraform-tunnel`) | Account → Cloudflare Tunnel → Edit; Account → Account Settings → Read | Future TF for tunnel *create* (today: dashboard create + connector token in Vault; ingress already in `cloudflare-tunnel.tf`) |
| **R2** (`platform-terraform-r2`) | Account → Workers R2 Storage → Edit | Terraform for R2 buckets, lifecycle rules, CORS — Memex file storage, static assets with no egress fees |

Store each as its own SM secret (e.g. `personal/cloudflare-r2-api-token`) with a dedicated
IAM grant on the consuming pipeline role. Do not widen the personal DNS token.

---

## 4. HCP Terraform and SM

Long-lived secrets are read from SM at plan/apply time — not stored as HCP workspace variables.

| Secret / config | In HCP workspace? | SM path |
|---|---|---|
| `github_app_id` | Yes (terraform var) | — |
| `github_app_installation_id` | Yes | — |
| `specterrealm_github_app_installation_id` | Yes | — |
| `mccleaton_github_app_installation_id` | Yes | — |
| GitHub App PEM | **No** | `platform-bootstrap/github-app-pem` |
| HCP org API token | **No** | `platform-bootstrap/tfe-api-token` |

When rotating the App private key: `put-secret-value` in SM only — next HCP plan picks it up.
When rotating the HCP org API token: update SM only.

---

## 5. IAM access

Terraform grants scoped SM read on `platform-bootstrap/*` to:

| IAM role | How |
|---|---|
| `platform-bootstrap-github-actions` | `bootstrap_ci_management` policy (GHA plan/apply) |
| `platform-bootstrap-tfe` | `platform-bootstrap-tfe-secrets-access` policy (HCP dynamic creds) |

```text
secretsmanager:GetSecretValue  on  arn:aws:secretsmanager:us-west-2:336090301942:secret:platform-bootstrap/*
```

Workstation users use the `platform-bootstrap` AWS profile with broader SM access for manual
uploads. Do not grant `platform-bootstrap/*` read to unrelated spoke workspaces.

Spoke **TFE** roles (e.g. `shared-cloudflare-dns-tfe`) receive scoped
`secretsmanager:GetSecretValue` via their pipeline IAM policy when the secret is listed in the
pipeline entry.

**GHA OIDC** roles (`personal-aws-curseforge-*-github-actions`) receive scoped SM read when
`personal/curseforge-api-key` is listed on the pipeline entry. Terraform sets
`AWS_CURSEFORGE_UPLOAD_ROLE_ARN` on `minecraft-modpack-cp-verdant` and `specterrealm-core`.

Legacy GHA OIDC roles on other spokes may still exist for validate-only workflows — see
[09-cloudflare-terraform-repo.md](./09-cloudflare-terraform-repo.md).

---

## 6. Rotation

| Secret | How to rotate |
|---|---|
| `platform-bootstrap/github-app-pem` | GitHub App → Generate new private key → `put-secret-value` in SM → delete old key in GitHub |
| `platform-bootstrap/tfe-api-token` | HCP → new org API token → `put-secret-value` in SM → revoke old token |
| `personal/linear-api-token` | Linear settings → new token → `put-secret-value` → update MCP env |
| `personal/notion-api-token` | Notion integration → refresh secret → `put-secret-value` → update MCP env |
| `personal/cloudflare-api-token` | Cloudflare dashboard → roll token → `put-secret-value` → update spoke repos / env |
| `personal/curseforge-api-key` | CurseForge Console → revoke old key → create new → `put-secret-value` (no GitHub secret to update) |
| `personal/slack-bot-token` | Slack app → reinstall / rotate bot token → `put-secret-value` → refresh homelab Vault/n8n |
| `personal/discord-bot-token` | Discord Developer Portal → Bot → Reset Token → `put-secret-value` |
| `personal/discord-webhook-url` | Discord channel webhook → regenerate URL → `put-secret-value` |

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
- [10 — Comms integrations (Slack + Discord)](./10-comms-integrations.md)
- [Issue #51 — Migrate secrets to AWS Secrets Manager](https://github.com/MichaelHeaton/platform-bootstrap/issues/51) (closed)
- [Issue #63 — Post-cloudflare rollout housekeeping](https://github.com/MichaelHeaton/platform-bootstrap/issues/63)
- `AGENTS.md` — credential tier strategy
