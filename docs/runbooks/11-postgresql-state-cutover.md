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
- Apply: extend with a gated apply workflow when ready; until then use break-glass
  `tofu apply` on the runner after plan review.

## Status (2026-09-10)

Cutover complete: HCP serial 154 pushed to `homelab_platform`; local `tofu plan` → **No changes**.
HCP workspace VCS disconnected + `auto-apply=false`.
