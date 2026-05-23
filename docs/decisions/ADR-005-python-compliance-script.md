# ADR-005: Python Script for Compliance Drift Detection (Not OPA or Checkov)

**Status:** Accepted
**Date:** 2025-05-22
**Deciders:** @MichaelHeaton

## Context

We need compliance checking — verifying that actual infrastructure state matches expected
configuration and that security invariants hold. Options include dedicated policy-as-code
tools (OPA, Checkov, Terrascan), cloud-native rule engines (AWS Config Rules), or a custom
script. The checks we need span both AWS resources and the GitHub API, which dedicated IaC
scanning tools do not cover uniformly.

## Decision

Implement compliance checking as a standalone Python script at `scripts/compliance_check.py`.

Rationale:

- **Runnable locally without extra tooling:** `python scripts/compliance_check.py --structural-only`
  runs without any credentials or external dependencies beyond the Python standard library and
  boto3 (already common in AWS-adjacent environments).
- **Plain-English output with remediation steps:** Each failing check prints the exact command
  or config change needed to fix it. Policy violation codes (e.g., CKV_AWS_18) require
  cross-referencing documentation; this script does not.
- **Structural checks run credentialless:** Checks that validate Terraform file structure,
  variable naming conventions, and ADR cross-references run in CI on every PR without AWS
  or GitHub credentials.
- **No policy language to learn:** New checks are added as Python methods — no Rego, no
  Checkov custom policies, no YAML rule definitions. The check logic is reviewable by anyone
  who knows Python.
- **Unified API access:** The same script can call `boto3` (AWS) and the GitHub REST API
  (`requests` or `PyGithub`) in the same run, making it possible to detect cross-system
  drift (e.g., a GitHub repo that exists but has no corresponding Terraform state path).
- **Standard testability:** Tests live in `scripts/tests/` and run with `pytest` — the same
  tool used for everything else.

## Consequences

- We maintain the script. It is not a third-party tool with automatic upstream rule updates.
  New compliance requirements must be explicitly added as new check methods.
- Python must be available in CI. On `ubuntu-latest` this is always true (Python 3.x is
  pre-installed).
- The script is longer than a Checkov config file, but the output is more actionable for
  operators who are not Terraform experts.
- Tests live alongside the script and are part of the standard CI run.
- The `--structural-only` flag allows the CI job on PRs to run without needing AWS credentials
  while still catching structural regressions.

## Alternatives Considered

- **Checkov:** Good for IaC static analysis (catches misconfigured S3 buckets, open security
  groups, etc.) but output is not user-friendly for non-Terraform-experts and it does not
  cover GitHub API checks. Could complement this script but does not replace it.
- **OPA / Rego:** Powerful and auditable, but introduces a new policy language. Policy-as-code
  is appropriate at larger scale; it is overkill for a single-team platform at this stage.
- **AWS Config Rules:** Adds per-rule cost; does not cover GitHub-side checks; difficult to
  test locally; requires an AWS account to develop against.
- **Terrascan:** Similar tradeoffs to Checkov. IaC-focused, not cross-system.

## Future State

If compliance requirements grow significantly (e.g., SOC 2, PCI-DSS audit evidence), dedicated
compliance tooling (Checkov in addition to this script, or OPA for policy-as-code) may be
warranted. A placeholder comment in `scripts/compliance_check.py` marks the extension point.
