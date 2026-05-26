# Runbook 05 — SpecterRealm pack GitHub settings

Configure a Minecraft modpack repository (NeoForge / packwiz) in GitHub via **platform-bootstrap**
Terraform — not the GitHub UI (except discussion categories; see below).

## Prerequisites

- Pack repo is listed in `terraform/managed.auto.tfvars` (`managed_repositories`).
- Community files live **in the pack repo** (issue templates, Prettier workflow, `MOD_ISSUES.md`,
  `CHANGELOG.md`, `docs/github-community.md`). See `docs/pack-template.md` in the pack repo.
- `CODEOWNERS` in the pack repo (`* @MichaelHeaton`) — the bootstrap module will not overwrite
  an existing file after first apply.

## Add settings for a new pack

1. Copy `terraform/pack-minecraft-modpack-cp-verdant.tf` to
   `terraform/pack-<repo-name>.tf` and adjust:
   - `pack_settings_*` local name
   - `labels` / `labels_remove` as needed
   - `pages` if GitHub Pages should be enabled for the pack repo
   - Add required discussion slugs to `scripts/github_repo_extras.py` → `PACK_DISCUSSION_SLUGS`
2. Wire the pack in `terraform/main.tf` `managed_repositories_resolved`:

   ```hcl
   repo.name == "my-new-pack"
   ? merge(repo, local.pack_settings_my_new_pack)
   : repo
   ```

3. Open a PR to **platform-bootstrap**. Review `terraform plan` (expect `has_discussions`,
   `github_issue_label`, optional `github_repository_pages`, optional `github_repository_ruleset`).
4. Merge — **terraform-apply** runs on `main`.
5. **Discussion categories (one-time UI):** GitHub has no public API to create categories.
   After apply enables Discussions:
   - `ideas` — usually already present (GitHub default; matches issue template contact link).
   - Create any other required slugs under **Settings → General → Discussions → New category**
     (for CP Verdant: **Mod suggestions**, slug `mod-suggestions`).

## Defaults (all managed repos)

Unless overridden per repo:

| Setting | Value |
|---------|--------|
| Issues | enabled |
| Wiki / Projects | disabled |
| Squash + merge commit | allowed |
| Rebase merge | disabled |
| Delete branch on merge | true |
| `main` branch protection | PR required, 0 approvals, no force-push, no delete |

Pack repos add: **Discussions**, **labels**, optional **ruleset**
(`deletion` + `non_fast_forward` on `main`), and optional **GitHub Pages**.

For CP Verdant, Pages uses **GitHub Actions** as the Pages source. The pack repo's
Pages workflow publishes the `docs/` directory by uploading it as the Pages artifact;
that `docs/` path is owned by the workflow in the pack repo, not by the repository
Pages source block in Terraform:

```hcl
pages = {
  build_type = "workflow"
}
```

Do not add a `source` branch/path block for CP Verdant unless it switches back to
legacy branch-based Pages publishing.

If Pages was enabled in the GitHub UI before Terraform management, add a declarative
`import` block so the first apply adopts the existing Pages site instead of trying to create it.
For CP Verdant this is tracked in `terraform/imports.tf`.

## Verify after apply

```bash
gh api repos/MichaelHeaton/<repo> --jq '{has_discussions, delete_branch_on_merge}'
gh api repos/MichaelHeaton/<repo>/pages --jq '{build_type, html_url, source, status}'
gh label list --repo MichaelHeaton/<repo> --limit 30
GITHUB_ORG=MichaelHeaton python3 scripts/github_repo_extras.py verify-discussion-categories --repo <repo>
```

- Issue chooser: `https://github.com/MichaelHeaton/<repo>/issues/new/choose` (three templates, no blank issue)
- Ideas category: `https://github.com/MichaelHeaton/<repo>/discussions/categories/ideas`
- Mod suggestions: `https://github.com/MichaelHeaton/<repo>/discussions/categories/mod-suggestions`

Compliance (`compliance-check` full mode) runs `verify-discussion-categories` for all packs in
`PACK_DISCUSSION_SLUGS`.

## Reference implementation

`minecraft-modpack-cp-verdant` — `terraform/pack-minecraft-modpack-cp-verdant.tf`.
