# Runbook 10 — Comms integrations (Slack + Discord)

**Estimated time:** ~30 minutes (initial app setup + Vault seed)

---

## 1. Overview

SpecterRealm **communication platforms** are factory-**documented** here (metadata in git).
**Secrets do not go in AWS Secrets Manager** — homelab runtime secrets live in **Vault**; the
operator stores copies in **Apple Password** (or 1Password later) for paste-at-seed, same as
other homelab n8n tokens.

| Platform | Role | Secret home |
| --- | --- | --- |
| **Slack** (`specterrealmworkspace.slack.com`) | Homelab ops inbox, n8n alert fan-out, MCP | Vault `homelab/n8n/slack` → ESO → n8n |
| **Discord** (`discord.gg/nqzt9RBGm`) | Family/gaming server (kids); optional homelab Tier-1 fan-out | Vault `homelab/n8n/discord` → ESO → n8n |

**Retired:** second personal Slack workspace (close after export). **Out of scope:** employer
Slack, MS Teams (M365 couple chat — not homelab automation unless explicitly added later).

This runbook does **not** use a Terraform spoke — no Slack/Discord provider in
`platform-bootstrap` today.

Cross-repo consumer: [homelab-infra `docs/n8n-alerting.md`](https://github.com/MichaelHeaton/homelab-infra/blob/main/docs/n8n-alerting.md).

### When AWS SM is still used (not comms)

SM remains only for **platform factory** secrets that HCP/GHA Terraform must read at plan time
without Vault on the LAN — e.g. `platform-bootstrap/github-app-pem`, `platform-bootstrap/tfe-api-token`,
and legacy pipeline tokens like `personal/cloudflare-api-token`. Do **not** add homelab or comms
tokens to SM; that adds cost and a second source of truth. See `AGENTS.md` credential tiers.

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
`ai-skills/config/local.template.json`. Never put bot tokens or webhook URLs in `local.json`.

**Operator copy:** save Slack bot token / Discord webhook URL in **Apple Password** (item per
integration) for rotation and paste into homelab seed scripts.

---

## 3. Vault inventory (homelab runtime)

| Vault path | Key(s) | Consumer |
| --- | --- | --- |
| `homelab/n8n/slack` | `webhook_url` or `bot_token` | n8n homelab-alert workflow → `#homelab-alerts` |
| `homelab/n8n/discord` | `webhook_url` | n8n optional Tier-1 fan-out (dedicated channel) |

Seed from mgmt VLAN (same pattern as `scripts/seed-n8n-notify-vault.sh`):

```bash
cd /Users/michaelheaton/Projects/specterrealm/homelab/homelab-infra
vault login   # or ensure VAULT_TOKEN
# Paste from Apple Password when prompted — scripts TBD (#99)
# bash scripts/seed-n8n-slack-vault.sh
# bash scripts/seed-n8n-discord-vault.sh
kubectl -n automation rollout restart deployment/n8n
```

Full inventory: [homelab-infra `docs/vault-secrets-inventory.md`](https://github.com/MichaelHeaton/homelab-infra/blob/main/docs/vault-secrets-inventory.md).

Verify after seed:

```bash
vault kv get homelab/n8n/slack
vault kv get homelab/n8n/discord
kubectl -n automation get externalsecret n8n-slack n8n-discord
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
6. Save token in **Apple Password** → seed Vault `homelab/n8n/slack`.

**n8n:** prefer **incoming webhook** for Tier-1 alerts (no OAuth refresh): Slack → channel →
Integrations → Incoming Webhooks → store URL in Vault key `webhook_url`. Use `bot_token` only when
you need threads, reactions, or slash commands.

---

## 5. Discord bootstrap

**Server:** join via `https://discord.gg/nqzt9RBGm`. Kids/family gaming — keep homelab traffic
in a dedicated channel (e.g. `#homelab-alerts` or `#server-status`) with restricted permissions.

**One-way alerts (simplest):**

1. Server Settings → Integrations → Webhooks → New Webhook.
2. Channel: dedicated homelab channel (not general gaming chat).
3. Copy webhook URL → **Apple Password** → seed Vault `homelab/n8n/discord` key `webhook_url`.

**Bot (optional — games, interactive):**

1. [Discord Developer Portal](https://discord.com/developers/applications) → New Application.
2. Bot → Reset Token → Apple Password (not Vault unless a bot consumer exists).
3. OAuth2 URL Generator: `bot` scope, permissions: Send Messages, Embed Links.
4. Invite bot to server; restrict to homelab channel.

---

## 6. Workstation MCP (optional)

For Cursor/Claude Slack or Discord MCP: read token from **Apple Password** or workstation
Keychain — mirror Linear/Notion in `workstation-devops` (see platform issue #100). Do not
replicate into AWS SM.

---

## 7. Rotation

| Secret | How to rotate |
| --- | --- |
| Slack webhook / bot token | Regenerate in Slack → update Apple Password → `vault kv put` or re-run seed script → ESO refresh → restart n8n if needed |
| Discord webhook | Discord channel webhook → regenerate → Apple Password → Vault → ESO |

---

## 8. Notification routing (homelab)

| Tier | Alerts | Destinations |
| --- | --- | --- |
| 1 — urgent | UPS, Vault sealed, K3s node down | Mobile push (ntfy) + Slack `#homelab-alerts` |
| 2 — ticket | All auto-issues | GitHub only |
| 3 — family | Optional UPS | Discord homelab channel (opt-in) |

GitHub Issues remain the **system of record**. Chat is attention, not triage.

---

## 9. Related

- [homelab-infra — n8n alerting](https://github.com/MichaelHeaton/homelab-infra/blob/main/docs/n8n-alerting.md)
- [homelab-infra — vault secrets inventory](https://github.com/MichaelHeaton/homelab-infra/blob/main/docs/vault-secrets-inventory.md)
- [08 — AWS Secrets Manager](./08-aws-secrets-manager.md) — **factory-only** secrets (not comms)
- Platform issues: #98 (app bootstrap + Vault seed), #99 (n8n routing), #100 (workstation MCP)
