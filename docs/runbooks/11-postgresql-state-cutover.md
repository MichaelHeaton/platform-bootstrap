# Platform-bootstrap PostgreSQL state cutover (#97)

Factory state lives in `pg-lxc-01` schema `homelab_platform` (role `tofu_platform`).
Plan/apply runs on `runner-lxc-01` via a **sibling** GitHub Actions runner registered
to this repo (`/opt/actions-runner-platform-bootstrap` — personal accounts cannot share
one repo-scoped runner across repos).

## One-time cutover

1. **Sibling runner (homelab-infra):** seed + Ansible
   - `bash scripts/seed-platform-bootstrap-runner-vault.sh` (in homelab-infra)
   - Ansible Run → `bootstrap-github-runner-platform-bootstrap.yml`
2. **CI secrets/vars on this repo:**
   - `VAULT_APPROLE_ROLE_ID` / `VAULT_APPROLE_SECRET_ID` (same AppRole as homelab-infra CI)
   - GitHub Actions **variables** formerly on the HCP workspace: `GH_APP_ID`,
     `GH_APP_INSTALLATION_ID`, `SPECTERREALM_GITHUB_APP_INSTALLATION_ID`,
     `MCCLEATON_GITHUB_APP_INSTALLATION_ID`, `SPECTERREALM_HOMELAB_GITHUB_APP_INSTALLATION_ID`,
     `TFE_VCS_OAUTH_TOKEN_ID` (names must not start with `GITHUB_` — Actions rejects that prefix)
3. **Disable HCP auto-apply / VCS** on `McCleaton-Bootstrap/platform-bootstrap` before merging
   the `backend "pg"` change (HCP cannot reach VLAN 1).
4. Merge this PR → dispatch **OpenTofu Plan** → `action=migrate-state`.
   - Migrate job reads `TF_TOKEN_app_terraform_io` from Vault `homelab/hcp/tfe-api-token`
     (seed once from SM `platform-bootstrap/tfe-api-token` — sibling runner has no `aws` CLI).
   - If `pq: permission denied for sequence global_states_id_seq`, grant
     `ALL ON SEQUENCE public.global_states_id_seq` to `tofu_platform` (owned by first writer).
5. Confirm plan is clean; leave HCP workspace disabled (or delete after soak).

## Day-to-day

- PR / push to `main` touching `terraform/**` → **OpenTofu Plan** on `[self-hosted, linux, homelab]`.
- Apply → **OpenTofu Apply (gated)** — you start it in the **GitHub Actions UI**
  (`workflow_dispatch` only). The apply job itself runs on the **LAN sibling self-hosted
  runner** on `runner-lxc-01` (`/opt/actions-runner-platform-bootstrap`, labels
  `[self-hosted, linux, homelab]`), same as Plan — **not** GitHub-hosted `ubuntu-latest`,
  and **not** an interactive Guacamole/SSH shell. Two gates:
  1. Set `confirm_apply=yes` (same pattern as homelab-infra Deploy Workload).
  2. Approve the GitHub Environment **`opentofu-apply`** (required reviewers).

Do **not** use interactive `tofu apply` on `runner-lxc-01` for routine factory/DNS
changes (Guacamole/SSH/env drift). Prefer the gated Action.

### One-time: configure Environment `opentofu-apply`

GitHub does not create Environments from workflow YAML alone. Before the first apply:

1. Repo **Settings → Environments → New environment** → name exactly `opentofu-apply`.
2. **Required reviewers:** add yourself (and any other operator). Admins can bypass if
   `Allow administrators to bypass` stays on — prefer reviewing anyway.
3. Optional: **Deployment branches** → Selected branches → `main` only.
4. Save. First **OpenTofu Apply (gated)** run will pause on the Environment until approved.

Secrets/vars are **repo-level** (same as OpenTofu Plan) — do not duplicate them onto the
Environment unless you intentionally want Environment-scoped overrides.

### Ops steps (apply after a reviewed plan)

1. Confirm latest **OpenTofu Plan** on `main` shows the expected changes (e.g. kb-mcp CNAME).
2. In GitHub: **Actions → OpenTofu Apply (gated) → Run workflow** → branch `main` →
   `confirm_apply=yes` → Run. (This is the only operator click path — no SSH.)
3. Open the run → **Review deployments** → approve Environment `opentofu-apply`.
4. GitHub schedules the `apply` job onto the sibling runner on VLAN 1; that job does
   Vault AppRole → AWS OIDC → `tofu plan -out` → `tofu apply` saved plan → post-apply
   plan must be clean. You watch the run in the Actions UI.

## Status (2026-09-10)

Cutover complete: HCP serial 154 pushed to `homelab_platform`; local `tofu plan` → **No changes**.
HCP workspace VCS disconnected + `auto-apply=false`.

## Status (2026-09-16)

Gated apply workflow added (`opentofu-apply.yml`). Operator must still create/configure the
`opentofu-apply` Environment with required reviewers (above) before the first successful apply.
Unblocks Terraform-owned Cloudflare Tunnel DNS (e.g. `kb-mcp` CNAME from #105) without CLI apply.
