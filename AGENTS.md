# AGENTS.md

## Cursor Cloud specific instructions

This is an infrastructure-as-code (Terraform + Python) repository with no application services to run. Development work involves Terraform configuration and a Python compliance script.

### Quick reference

| Task | Command |
|---|---|
| Run Python tests | `pytest scripts/tests/ -v` |
| Structural compliance check | `python3 scripts/compliance_check.py --structural-only` |
| Terraform format check | `terraform -chdir=terraform fmt -check -recursive` |
| Terraform validate | `terraform -chdir=terraform init -backend=false && terraform -chdir=terraform validate` |
| Auto-format Terraform | `terraform -chdir=terraform fmt -recursive` |
| All Makefile targets | `make help` |

### Non-obvious caveats

- **GitHub repo creation is managed here**: when asked to create or change a GitHub repository, add or update an entry in `terraform/managed.auto.tfvars` under `managed_repositories`; do not try to create repositories imperatively with `gh repo create` or the GitHub API from Cursor Cloud. CI/CD will run Terraform plan/apply after the PR is merged.
- **New repo requests have an issue form**: prefer using `.github/ISSUE_TEMPLATE/new-repository.yml` as the source of truth for repository name, visibility, default branch, license, Pages, Discussions, and service-account needs. Public repos should include a supported `license` block when added to `managed_repositories`.
- **Terraform init requires `-backend=false`** for local validation. The S3 backend needs real AWS credentials and bucket config, so always use `terraform init -backend=false` when running `validate` or `fmt` locally without AWS access.
- **Python path for pytest**: pytest resolves imports via `sys.path` manipulation in the test files themselves, so running `pytest scripts/tests/ -v` from the repo root works without extra `PYTHONPATH` setup.
- **No `requirements.txt`**: Python dependencies (`pytest`) are installed directly via `pip3 install pytest`. The compliance script's heavy dependencies (`boto3`, `requests`) are optional and only needed for full (non-structural) checks that require AWS/GitHub credentials.
- **Terraform >= 1.10.0 is required** (for S3 native state locking). The update script installs Terraform 1.15.4 to `/usr/local/bin/terraform`. To upgrade, change the version in the update script.
- The `.terraform/` directory created by `terraform init` is gitignored and ephemeral; re-run init after a fresh clone.
