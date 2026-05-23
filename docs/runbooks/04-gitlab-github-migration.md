# Runbook 04 — GitLab → GitHub Migration

**Estimated time:** 2–4 hours per repository (first time) / 30–60 minutes per repository
(subsequent, once tooling is in place)

---

## 1. Overview

This runbook migrates repositories from GitLab to GitHub in seven phases:

| Phase | What happens |
|---|---|
| 1 | Inventory — catalogue every repository and its contents |
| 2 | Terraform registration — create GitHub repos via PR to platform-bootstrap |
| 3 | Git mirror — copy all branches, tags, and history |
| 4 | Issue & MR migration — re-create open issues and merge requests as GitHub Issues/PRs |
| 5 | CI conversion — translate `.gitlab-ci.yml` to GitHub Actions workflows |
| 6 | Secret migration — move CI/CD variables from GitLab to GitHub |
| 7 | Cutover & archive — redirect traffic, archive GitLab repos |

Work through phases 1–2 for **all** repositories before starting phase 3. Phases 3–7 can be
done one repository at a time or in parallel once the Terraform PR has merged.

---

## 2. Prerequisites

- **GitHub personal access token** with `repo`, `workflow`, and `read:org` scopes.
  Set as `GITHUB_TOKEN` in your shell.
- **GitLab personal access token** with `api` scope.
  Set as `GITLAB_TOKEN` in your shell.
- **`gh` CLI** installed and authenticated (`gh auth login`)
- **`git`** >= 2.30
- **`python3`** >= 3.11 with `requests` installed (`pip install requests`)
- **`jq`** installed

```bash
# Verify tooling
gh auth status
git --version
python3 --version
python3 -c "import requests; print('requests ok')"
jq --version
```

Set these variables once — they are used throughout this runbook:

```bash
export GITLAB_TOKEN="<your-gitlab-token>"
export GITHUB_TOKEN="<your-github-token>"
export GITLAB_GROUP="<your-gitlab-group-or-username>"   # e.g. mccleaton
export GITHUB_ORG="<your-github-org-or-username>"       # e.g. MichaelHeaton
export GITLAB_HOST="gitlab.com"                          # or your self-managed host
```

---

## 3. Phase 1 — Inventory

Run the following script to produce a migration inventory. It lists every repository in your
GitLab group with its open issue count, open MR count, active CI status, and size.

```bash
# Save as /tmp/gitlab-inventory.py and run it
python3 - <<'PYEOF'
import os, json, requests

token  = os.environ["GITLAB_TOKEN"]
group  = os.environ["GITLAB_GROUP"]
host   = os.environ.get("GITLAB_HOST", "gitlab.com")
base   = f"https://{host}/api/v4"
h      = {"PRIVATE-TOKEN": token}

# Paginate all projects in the group
projects, page = [], 1
while True:
    r = requests.get(f"{base}/groups/{group}/projects",
                     params={"per_page": 100, "page": page,
                             "include_subgroups": True}, headers=h)
    r.raise_for_status()
    batch = r.json()
    if not batch:
        break
    projects.extend(batch)
    page += 1

print(f"{'NAME':<40} {'ISSUES':>6} {'MRS':>4} {'CI':>5} {'MB':>6}")
print("-" * 65)
for p in sorted(projects, key=lambda x: x["name"]):
    issues = p.get("open_issues_count", 0)
    mrs    = requests.get(f"{base}/projects/{p['id']}/merge_requests",
                          params={"state": "opened", "per_page": 1}, headers=h
                          ).headers.get("X-Total", "?")
    has_ci = requests.get(f"{base}/projects/{p['id']}/repository/files/.gitlab-ci.yml",
                          params={"ref": p.get("default_branch","main")}, headers=h
                          ).status_code == 200
    mb     = round(p.get("statistics", {}).get("repository_size", 0) / 1_048_576, 1)
    print(f"{p['name']:<40} {issues:>6} {mrs:>4} {'yes' if has_ci else 'no':>5} {mb:>6}")
PYEOF
```

Save the output. For each repository, note:

- **Needs CI conversion?** (yes/no)
- **Open issues to migrate?** (count)
- **Open MRs to migrate?** (count)
- **GitLab-specific features in use?** (Pages, Packages, Environments, Protected Branches)

Flag any repository where `MB > 500` for a separate large-file review before proceeding.

---

## 4. Phase 2 — Terraform Registration

For each repository being migrated, add an entry to `var.managed_repositories` in
`terraform/main.tf` of the `platform-bootstrap` repository. Do this in a **single PR** for all
repositories being migrated at once.

### 4a. Open a branch and edit `terraform/main.tf`

```bash
cd /path/to/platform-bootstrap
git checkout -b feat/gitlab-migration-repos
```

In `terraform/main.tf`, locate the `module "github_repos"` block and add each migrated
repository to the `repositories` list inside `var.managed_repositories` in
`terraform/variables.tf` (or however `managed_repositories` is populated in your configuration).

Example entry for each repository:

```hcl
{
  name           = "my-service"
  description    = "Brief description carried over from GitLab"
  visibility     = "private"   # or "public" — match the GitLab visibility
  topics         = ["python", "api"]  # optional, from GitLab tags
  default_branch = "main"
}
```

> **Visibility:** If a GitLab repository is `internal`, set GitHub visibility to `private`.
> GitLab `internal` (visible to all group members) maps most closely to GitHub `private` with
> org membership. Changing to `public` requires a separate review via the
> `pre-publication-audit` workflow — do not set `visibility = "public"` here without that review.

### 4b. Open the PR

```bash
git add terraform/
git commit -m "feat: register migrated GitLab repositories in Terraform"
git push -u origin feat/gitlab-migration-repos
gh pr create --title "feat: register GitLab migration repositories" \
  --body "Registers repositories being migrated from GitLab. No infrastructure changes — repositories do not exist on GitHub yet, so Terraform will create them on apply."
```

The `terraform-plan` workflow will run automatically and post the plan as a PR comment. Review
it: every repository should appear as `will be created`, with no unexpected destroys.

Merge the PR. The `terraform-apply` workflow creates the GitHub repositories with branch
protection and CODEOWNERS initialised.

---

## 5. Phase 3 — Git Mirror

Run this for each repository after the Terraform apply has completed (the GitHub repo exists).

```bash
# Set per-repo variables
REPO_NAME="my-service"
GITLAB_URL="git@${GITLAB_HOST}:${GITLAB_GROUP}/${REPO_NAME}.git"
GITHUB_URL="git@github.com:${GITHUB_ORG}/${REPO_NAME}.git"

# Clone a bare mirror from GitLab (includes all branches, tags, and refs)
git clone --mirror "$GITLAB_URL" "/tmp/${REPO_NAME}.git"
cd "/tmp/${REPO_NAME}.git"

# Push everything to GitHub
# --mirror pushes all refs (branches, tags, notes)
git push --mirror "$GITHUB_URL"

# Verify: branch and tag counts should match
echo "GitLab branches/tags:"
git branch -a | wc -l

echo "GitHub branches/tags:"
gh api "repos/${GITHUB_ORG}/${REPO_NAME}/branches" --paginate | jq 'length'
gh api "repos/${GITHUB_ORG}/${REPO_NAME}/tags"     --paginate | jq 'length'
```

> **Large repos (> 500 MB):** If the repository contains files > 100 MB, Git LFS is required on
> GitHub. See the GitHub docs on migrating to Git LFS before pushing. The inventory in Phase 1
> flags repositories over this threshold.

> **Default branch:** GitHub creates the repository with `main` as the default (set by
> Terraform). If the GitLab default branch is different (e.g. `master`), rename it after the
> mirror:
>
> ```bash
> gh api -X PATCH "repos/${GITHUB_ORG}/${REPO_NAME}" \
>   -f default_branch=main
> ```

---

## 6. Phase 4 — Issue & MR Migration

This phase migrates **open** GitLab issues and merge requests to GitHub Issues and Pull Requests.
Closed items are not migrated — they remain accessible on the archived GitLab repository.

> **Note on MR migration:** GitLab merge requests with open diffs cannot be faithfully
> reproduced as GitHub PRs unless the source branch exists on GitHub. Phase 3 mirrors all
> branches, so source branches for open MRs will be present. However, review threads and
> approvals are not migrated — only the title, description, and labels.

Save the following script as `/tmp/migrate-issues.py`:

```python
#!/usr/bin/env python3
"""Migrate open GitLab issues and MRs to GitHub Issues/PRs for one repository."""
import os, sys, time, requests

GITLAB_TOKEN  = os.environ["GITLAB_TOKEN"]
GITHUB_TOKEN  = os.environ["GITHUB_TOKEN"]
GITLAB_HOST   = os.environ.get("GITLAB_HOST", "gitlab.com")
GITLAB_GROUP  = os.environ["GITLAB_GROUP"]
GITHUB_ORG    = os.environ["GITHUB_ORG"]
REPO_NAME     = sys.argv[1]  # pass repo name as argument

GL_BASE = f"https://{GITLAB_HOST}/api/v4"
GH_BASE = "https://api.github.com"
GL_H    = {"PRIVATE-TOKEN": GITLAB_TOKEN}
GH_H    = {"Authorization": f"Bearer {GITHUB_TOKEN}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28"}

def gl_get_all(url, params=None):
    items, page = [], 1
    while True:
        r = requests.get(url, headers=GL_H,
                         params={**(params or {}), "per_page": 100, "page": page})
        r.raise_for_status()
        batch = r.json()
        if not batch:
            break
        items.extend(batch)
        page += 1
    return items

def gh_post(url, data):
    r = requests.post(url, headers=GH_H, json=data)
    if r.status_code == 403 and "rate limit" in r.text.lower():
        reset = int(r.headers.get("X-RateLimit-Reset", time.time() + 60))
        wait  = max(reset - int(time.time()), 1)
        print(f"  Rate limited — sleeping {wait}s")
        time.sleep(wait)
        return gh_post(url, data)
    r.raise_for_status()
    return r.json()

# Resolve GitLab project ID
projects = requests.get(f"{GL_BASE}/groups/{GITLAB_GROUP}/projects",
                        params={"search": REPO_NAME}, headers=GL_H).json()
project  = next((p for p in projects if p["name"] == REPO_NAME), None)
if not project:
    sys.exit(f"Project '{REPO_NAME}' not found in GitLab group '{GITLAB_GROUP}'")
pid = project["id"]

# Migrate open issues
issues = gl_get_all(f"{GL_BASE}/projects/{pid}/issues", {"state": "opened"})
print(f"Migrating {len(issues)} open issues for {REPO_NAME}...")
for issue in sorted(issues, key=lambda x: x["iid"]):
    body  = issue.get("description") or ""
    body += f"\n\n---\n_Migrated from GitLab issue #{issue['iid']}: {issue['web_url']}_"
    labels = [l["name"] for l in (issue.get("labels") or [])]
    data  = {"title": issue["title"], "body": body}
    if labels:
        data["labels"] = labels
    result = gh_post(f"{GH_BASE}/repos/{GITHUB_ORG}/{REPO_NAME}/issues", data)
    print(f"  GL #{issue['iid']} → GH #{result['number']}: {issue['title'][:60]}")
    time.sleep(0.5)  # stay under secondary rate limits

# Migrate open MRs
mrs = gl_get_all(f"{GL_BASE}/projects/{pid}/merge_requests", {"state": "opened"})
print(f"Migrating {len(mrs)} open MRs for {REPO_NAME}...")
for mr in sorted(mrs, key=lambda x: x["iid"]):
    body  = mr.get("description") or ""
    body += f"\n\n---\n_Migrated from GitLab MR !{mr['iid']}: {mr['web_url']}_"
    src   = mr.get("source_branch", "")
    tgt   = mr.get("target_branch", "main")
    # Only create as a PR if source branch exists on GitHub
    branches = requests.get(f"{GH_BASE}/repos/{GITHUB_ORG}/{REPO_NAME}/branches/{src}",
                             headers=GH_H)
    if branches.status_code == 200:
        data = {"title": mr["title"], "body": body, "head": src, "base": tgt}
        result = gh_post(f"{GH_BASE}/repos/{GITHUB_ORG}/{REPO_NAME}/pulls", data)
        print(f"  GL !{mr['iid']} → GH PR #{result['number']}: {mr['title'][:60]}")
    else:
        # Branch missing — fall back to an issue with [MR] prefix
        data = {"title": f"[MR] {mr['title']}", "body": body,
                "labels": ["migrated-mr"]}
        result = gh_post(f"{GH_BASE}/repos/{GITHUB_ORG}/{REPO_NAME}/issues", data)
        print(f"  GL !{mr['iid']} → GH Issue #{result['number']} (branch not found): "
              f"{mr['title'][:60]}")
    time.sleep(0.5)

print("Done.")
```

Run it once per repository:

```bash
python3 /tmp/migrate-issues.py my-service
```

> **Label pre-creation:** If your GitLab issues use custom labels, create matching labels in
> GitHub before running the script, otherwise the API will silently drop unknown labels:
>
> ```bash
> gh label create "bug" --color d73a4a --repo "${GITHUB_ORG}/my-service"
> ```

---

## 7. Phase 5 — CI Conversion

There is no automated tool that reliably converts GitLab CI to GitHub Actions. The following
table covers the most common patterns.

### GitLab CI → GitHub Actions mapping

| GitLab concept | GitHub Actions equivalent |
|---|---|
| `.gitlab-ci.yml` | `.github/workflows/<name>.yml` |
| `stages:` | Job ordering via `needs:` |
| `stage: test` | `needs: [build]` or `jobs.test` |
| `image: node:20` | `runs-on: ubuntu-latest` + `container: node:20` or `uses: actions/setup-node` |
| `variables:` (global) | `env:` at workflow level |
| `rules: - if: $CI_PIPELINE_SOURCE == "merge_request_event"` | `on: pull_request:` |
| `rules: - if: $CI_COMMIT_BRANCH == "main"` | `on: push: branches: [main]` |
| `only: [main]` (legacy) | `on: push: branches: [main]` |
| `artifacts: paths:` | `actions/upload-artifact` / `actions/download-artifact` |
| `cache: key: paths:` | `actions/cache` |
| `extends:` / YAML anchors | Reusable workflows (`uses: ./.github/workflows/shared.yml`) |
| `include:` (remote template) | Reusable workflows or composite actions |
| `environment: production` | `environment: production` (same concept) |
| `needs: [job-a]` | `needs: [job-a]` (same) |
| `when: manual` | `environment:` with required reviewers, or `workflow_dispatch:` |
| `$CI_COMMIT_SHA` | `${{ github.sha }}` |
| `$CI_COMMIT_REF_NAME` | `${{ github.ref_name }}` |
| `$CI_PROJECT_NAME` | `${{ github.event.repository.name }}` |
| `$CI_REGISTRY_IMAGE` | Set as a workflow-level `env:` variable |
| `$CI_ENVIRONMENT_URL` | `${{ steps.deploy.outputs.url }}` (step output) |

### AWS authentication

The existing OIDC model from ADR-002 covers new repositories automatically once they are added
to the `oidc-roles` module's `pipelines` variable. Add an entry for each migrated repository
that needs AWS access:

In `terraform/variables.tf` (or wherever `var.pipelines` is defined), add:

```hcl
{
  name       = "my-service"
  repo       = "my-service"
  state_path = "my-service"  # S3 prefix for this repo's Terraform state, if any
}
```

Open a separate PR to platform-bootstrap for the OIDC role additions.

### Minimal GitHub Actions workflow template

```yaml
# .github/workflows/ci.yml
name: CI

on:
  push:
    branches: [main]
  pull_request:

permissions:
  contents: read

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Set up runtime
        uses: actions/setup-node@v4   # or setup-python, setup-go, etc.
        with:
          node-version: "20"
          cache: npm
      - run: npm ci
      - run: npm test
```

Commit the converted workflow to the GitHub repository (not GitLab):

```bash
cd /path/to/local-clone-of-my-service
# add .github/workflows/ci.yml
git add .github/workflows/
git commit -m "ci: add GitHub Actions workflow (converted from GitLab CI)"
git push origin main
```

> The `terraform-apply` workflow in platform-bootstrap enforces branch protection. All pushes to
> `main` require a PR. Use a feature branch and open a PR for the CI workflow commit.

---

## 8. Phase 6 — Secret Migration

GitLab CI/CD variables become GitHub Actions secrets or variables.

| GitLab variable type | GitHub equivalent |
|---|---|
| Protected + Masked (sensitive) | Repository secret (`gh secret set`) |
| Non-sensitive | Repository variable (`gh variable set`) |
| Group-level variable | Organisation secret or variable |
| File-type variable | Secret containing the file contents; write to disk in the workflow step |

```bash
# List GitLab CI variables for a project (requires API token)
REPO_NAME="my-service"
PROJECT_ID=$(curl -s -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "https://${GITLAB_HOST}/api/v4/groups/${GITLAB_GROUP}/projects?search=${REPO_NAME}" \
  | jq -r '.[] | select(.name == "'$REPO_NAME'") | .id')

curl -s -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "https://${GITLAB_HOST}/api/v4/projects/${PROJECT_ID}/variables" \
  | jq '.[] | {key: .key, masked: .masked, protected: .protected, type: .variable_type}'
```

> **Security note:** GitLab's API returns variable *values* for non-masked variables. Treat this
> output as sensitive — do not log it or commit it. Pipe directly to `gh secret set`:
>
> ```bash
> gh secret set MY_SECRET \
>   --repo "${GITHUB_ORG}/my-service" \
>   --body "$(curl -s -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
>     "https://${GITLAB_HOST}/api/v4/projects/${PROJECT_ID}/variables/MY_SECRET" \
>     | jq -r '.value')"
> ```

---

## 9. Phase 7 — Cutover & Archive

Complete these steps in order. Do not archive the GitLab repository until all verification
checks pass.

### 9a. Update all external references

Search for and update any references to the old GitLab clone URL:

- Local developer clones: `git remote set-url origin git@github.com:${GITHUB_ORG}/${REPO_NAME}.git`
- Deploy keys on servers: replace with GitHub deploy keys (`gh repo deploy-key add`)
- Webhooks: re-create on GitHub (`gh api repos/${GITHUB_ORG}/${REPO_NAME}/hooks`)
- README badges pointing at GitLab CI status: update to GitHub Actions badge URLs
- Any documentation, wiki pages, or internal links to `gitlab.com` URLs

### 9b. Verification checklist

Run these checks for each repository before archiving:

```bash
REPO_NAME="my-service"

# 1. All branches and tags are present on GitHub
echo "=== Branch count ==="
git -C "/tmp/${REPO_NAME}.git" branch | wc -l
gh api "repos/${GITHUB_ORG}/${REPO_NAME}/branches" --paginate | jq 'length'
# Both counts must match

# 2. Latest commit SHA matches
echo "=== HEAD SHA ==="
git -C "/tmp/${REPO_NAME}.git" rev-parse HEAD
gh api "repos/${GITHUB_ORG}/${REPO_NAME}/commits/HEAD" | jq -r '.sha'
# Must be identical

# 3. CI is green on GitHub
echo "=== GitHub Actions status ==="
gh run list --repo "${GITHUB_ORG}/${REPO_NAME}" --limit 5

# 4. Issues migrated
echo "=== Open GitHub issues ==="
gh issue list --repo "${GITHUB_ORG}/${REPO_NAME}"

# 5. Terraform compliance check passes
cd /path/to/platform-bootstrap
python3 scripts/compliance_check.py --structural-only
```

### 9c. Archive the GitLab repository

Archive (do not delete) the GitLab repository via the GitLab API:

```bash
PROJECT_ID="<project-id-from-inventory>"
curl -s -X POST \
  -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "https://${GITLAB_HOST}/api/v4/projects/${PROJECT_ID}/archive"
# Returns the project object with "archived": true
```

Add a description update to make the archive reason visible:

```bash
curl -s -X PUT \
  -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"description\": \"ARCHIVED: migrated to https://github.com/${GITHUB_ORG}/${REPO_NAME} on $(date +%Y-%m-%d)\"}" \
  "https://${GITLAB_HOST}/api/v4/projects/${PROJECT_ID}"
```

> **Retention window:** Keep the GitLab repository archived for at least 90 days. After 90 days
> with no reported issues, the repository may be permanently deleted.

---

## 10. Removing the GitLab Placeholder from platform-bootstrap

Once all repositories are migrated and archived, remove the deferred GitLab placeholders:

1. In `terraform/main.tf`, delete the comment block:
   ```
   # DEFERRED: GitLab provider
   # Pending: GitLab support in target CI platform
   ```

2. Open a PR with the change and a note referencing this runbook and ADR-008.

---

## 11. Rollback

If a migrated repository needs to be rolled back to GitLab (e.g. a critical issue is found
post-cutover):

1. Un-archive the GitLab repository via the API:
   ```bash
   curl -s -X POST -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
     "https://${GITLAB_HOST}/api/v4/projects/${PROJECT_ID}/unarchive"
   ```
2. Re-point developer clones at the GitLab remote.
3. Do NOT push new commits to GitHub — freeze the GitHub repository by setting branch
   protection to block all pushes (`gh api -X PUT ...`).
4. Open an issue on platform-bootstrap to track the rollback and root-cause investigation.
5. Remove the repository entry from `var.managed_repositories` via a PR to platform-bootstrap
   once the repository is confirmed back on GitLab.

---

## 12. Reference

- ADR-008: `docs/decisions/ADR-008-gitlab-github-migration.md`
- ADR-004: `docs/decisions/ADR-004-github-terraform-management.md` (Terraform repo management)
- ADR-002: `docs/decisions/ADR-002-oidc-authentication.md` (OIDC for new repo pipelines)
- Runbook 02: `docs/runbooks/02-bootstrap.md` (adding OIDC roles for new repos)
- Runbook 03: `docs/runbooks/03-disaster-recovery.md`
