# Runbook 10 — Comms integrations (Slack + Discord)

**Estimated time:** ~30 minutes (initial app setup + SM upload)

---

## 1. Overview

SpecterRealm **communication platforms** are factory-managed like Linear, Notion, and Cloudflare
tokens: **metadata in git**, **tokens in AWS Secrets Manager**, **consumption in spokes**
(homelab n8n, workstation MCP).

This runbook does **not** use a Terraform spoke — there is no Slack/Discord provider in
`platform-bootstrap` today. Add Terraform only if channels/apps become substantial IaC later.

| Platform | Role | Managed here |
| --- | --- | --- |
| **Slack** (`specterrealmworkspace.slack.com`) | Homelab ops inbox, n8n alert fan-out, MCP | SM bot token; workspace URL in this doc |
| **Discord** (`discord.gg/nqzt9RBGm`) | Family/gaming server (kids); optional homelab Tier-1 fan-out | SM bot token (when needed); invite URL in this doc |

**Retired:** second personal Slack workspace (close after export). **Out of scope:** employer
Slack, MS Teams (M365 couple chat — not homelab automation unless explicitly added later).

Cross-repo consumer: [homelab-infra `docs/n8n-alerting.md`](https://github.com/MichaelHeaton/homelab-infra/blob/main/docs/n8n-alerting.md)
(notification routing v2).

---

## 2. Canonical metadata (not secrets — safe in git)

| Field | Value |
| --- | --- |
| Slack workspace name | SpecterRealm |
| Slack workspace URL | `https://specterrealmworkspace.slack.com` |
| Slack planned channel | `#homelab-alerts` (create manually or via future IaC) |
| Discord invite URL | `https://discord.gg/nqzt9RBGm` |
| Discord invite code | `nqzt9RBGm` |

Optional private copy in `~/.config/ai-skills/local.json` (`slack`, `discord` blocks) — see
`ai-skills/config/local.template.json`. Never put bot tokens in `local.json`.

---

## 3. AWS Secrets Manager inventory

| Secret name | Contents | Consumed by |
| --- | --- | --- |
| `personal/slack-bot-token` | `xoxb-…` bot token (homelab + MCP) | n8n (via Vault sync or direct SM on runner), workstation MCP |
| `personal/slack-signing-secret` | App signing secret | Only if hosting Slack event endpoints (not needed for incoming webhooks) |
| `personal/discord-bot-token` | Bot token | n8n, gaming/family bots (optional) |
| `personal/discord-webhook-url` | Channel webhook URL (optional) | n8n — simpler than bot for one-way alerts |

**Homelab runtime path (target):** SM → Vault sync (or operator seed) →
`homelab/n8n/slack` / `homelab/n8n/discord` → ESO → n8n env. See homelab-infra
`docs/vault-secrets-inventory.md`. Until wired, use `HOMELAB_NOTIFY_WEBHOOK_URL` for generic
webhooks (ntfy today).

Verify secrets exist (after upload):

```bash
export AWS_PROFILE=platform-bootstrap
export AWS_REGION=us-west-2

aws secretsmanager describe-secret --secret-id personal/slack-bot-token --query Name --output text
aws secretsmanager describe-secret --secret-id personal/discord-bot-token --query Name --output text
```

---

## 4. Slack app bootstrap

1. Open [Slack API → Your Apps](https://api.slack.com/apps) → **Create New App** → **From scratch**.
2. App name: `SpecterRealm Homelab` (or similar). Workspace: **SpecterRealm**
   (`specterrealmworkspace`).
3. **OAuth & Permissions** → Bot Token Scopes (minimum for n8n post):
   - `chat:write`
   - `chat:write.public` (if posting to public channels without joining)
4. **Install to Workspace** → copy **Bot User OAuth Token** (`xoxb-…`).
5. Create channel `#homelab-alerts` → invite the bot (`/invite @SpecterRealm Homelab`).
6. Upload token to SM (§5). For n8n **incoming webhook** alternative, Slack → channel →
   Integrations → Incoming Webhooks — store URL in `personal/discord-webhook-url` pattern as
   `personal/slack-incoming-webhook-url` if you prefer webhooks over bot API.

**n8n:** prefer incoming webhook for Tier-1 alerts (no OAuth refresh); bot token when you need
threads, reactions, or slash commands.

---

## 5. Discord bootstrap

**Server:** join via `https://discord.gg/nqzt9RBGm`. Kids/family gaming — keep homelab traffic
in a dedicated channel (e.g. `#homelab-alerts` or `#server-status`) with restricted permissions.

**One-way alerts (simplest):**

1. Server Settings → Integrations → Webhooks → New Webhook.
2. Channel: dedicated homelab channel (not general gaming chat).
3. Copy webhook URL → SM `personal/discord-webhook-url`.

**Bot (optional — games, interactive):**

1. [Discord Developer Portal](https://discord.com/developers/applications) → New Application.
2. Bot → Reset Token → SM `personal/discord-bot-token`.
3. OAuth2 URL Generator: `bot` scope, permissions: Send Messages, Embed Links.
4. Invite bot to server; restrict to homelab channel.

---

## 6. Upload secrets (CLI)

```bash
export AWS_PROFILE=platform-bootstrap
export AWS_REGION=us-west-2

read -s "?Slack bot token (xoxb-…): " SLACK_TOKEN; echo
aws secretsmanager create-secret \
  --name personal/slack-bot-token \
  --description "SpecterRealm Slack bot — homelab n8n + MCP" \
  --secret-string "$SLACK_TOKEN" \
  || aws secretsmanager put-secret-value \
    --secret-id personal/slack-bot-token \
    --secret-string "$SLACK_TOKEN"
unset SLACK_TOKEN
```

Repeat for `personal/discord-webhook-url` (webhook URL string) or `personal/discord-bot-token`.

---

## 7. Pipeline IAM (when a repo reads SM at runtime)

Add `secretsmanager_secret_names` to the consuming pipeline in `terraform/managed.auto.tfvars`
only when GHA or HCP must read the secret at plan/apply time. Example (homelab-infra break-glass
seed job — future):

```hcl
secretsmanager_secret_names = [
  "personal/slack-bot-token",
]
```

Workstation MCP uses the `platform-bootstrap` AWS profile directly — no pipeline entry required.

---

## 8. Rotation

| Secret | How to rotate |
| --- | --- |
| `personal/slack-bot-token` | Slack app → OAuth → Reinstall / rotate → `put-secret-value` → refresh Vault/n8n |
| `personal/slack-signing-secret` | Slack app → Basic Information → regenerate → `put-secret-value` |
| `personal/discord-bot-token` | Developer Portal → Bot → Reset Token → `put-secret-value` |
| `personal/discord-webhook-url` | Discord channel webhook → regenerate URL → `put-secret-value` |

---

## 9. Notification routing (homelab)

Factory intent (implemented in homelab-infra n8n — see platform issue tracker):

| Tier | Alerts | Destinations |
| --- | --- | --- |
| 1 — urgent | UPS, Vault sealed, K3s node down | Mobile push (ntfy) + Slack `#homelab-alerts` |
| 2 — ticket | All auto-issues | GitHub only |
| 3 — family | Optional UPS | Discord homelab channel (opt-in) |

GitHub Issues remain the **system of record**. Chat is attention, not triage.

---

## 10. Related

- [08 — AWS Secrets Manager](./08-aws-secrets-manager.md) — master inventory
- [homelab-infra — n8n alerting](https://github.com/MichaelHeaton/homelab-infra/blob/main/docs/n8n-alerting.md)
- Platform issues: comms factory registration, SM seed, homelab n8n routing (see GitHub)
