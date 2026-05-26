# Runbook 05 — SpecterRealm pack GitHub settings

Configure a Minecraft modpack repository (NeoForge / packwiz) in GitHub via **platform-bootstrap**
Terraform — not the GitHub UI.

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
   - `discussion_categories` (keep `ideas` slug if `config.yml` links to it)
   - `labels` / `labels_remove` as needed
2. Wire the pack in `terraform/main.tf` `managed_repositories_resolved`:

   ```hcl
   repo.name == "my-new-pack"
   ? merge(repo, local.pack_settings_my_new_pack)
   : repo
   ```

3. Open a PR to **platform-bootstrap**. Review `terraform plan` (expect `has_discussions`,
   `github_issue_label`, optional `github_repository_ruleset`, and `terraform_data` discussion
   category creates).
4. Merge — **terraform-apply** runs on `main`.

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

Pack repos add: **Discussions**, **labels**, **discussion categories**, optional **ruleset**
(`deletion` + `non_fast_forward` on `main`).

## Verify after apply

```bash
gh api repos/MichaelHeaton/<repo> --jq '{has_discussions, delete_branch_on_merge}'
gh label list --repo MichaelHeaton/<repo> --limit 30
```

- Issue chooser: `https://github.com/MichaelHeaton/<repo>/issues/new/choose` (three templates, no blank issue)
- Ideas category: `https://github.com/MichaelHeaton/<repo>/discussions/categories/ideas`

## Reference implementation

`minecraft-modpack-cp-verdant` — `terraform/pack-minecraft-modpack-cp-verdant.tf`.
