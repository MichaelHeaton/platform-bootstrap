"""
test_compliance_check.py

Unit tests for the structural checks in compliance_check.py.

Run with:
    pytest scripts/tests/test_compliance_check.py -v

No AWS credentials or GitHub token are required.
"""

from __future__ import annotations

import importlib
import os
import subprocess
import sys
import textwrap
from pathlib import Path
from typing import List

import pytest

# ---------------------------------------------------------------------------
# Ensure the scripts/ directory is on sys.path so we can import the module
# even when pytest is invoked from the repo root.
# ---------------------------------------------------------------------------
_SCRIPTS_DIR = Path(__file__).resolve().parent.parent
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))

import compliance_check as cc  # noqa: E402  (after sys.path manipulation)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(textwrap.dedent(content))


def _results_by_name(results: List[cc.CheckResult], name: str) -> List[cc.CheckResult]:
    return [r for r in results if r.name == name]


def _single(results: List[cc.CheckResult], name: str) -> cc.CheckResult:
    """Return the single result for a given check name, asserting exactly one exists."""
    matching = _results_by_name(results, name)
    assert matching, f"No result found for check {name!r}"
    assert len(matching) == 1, f"Expected 1 result for {name!r}, got {len(matching)}: {matching}"
    return matching[0]


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture()
def tmp_repo(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """
    Create a minimal fake repo layout and redirect compliance_check.REPO_ROOT
    to point at it.
    """
    monkeypatch.setattr(cc, "REPO_ROOT", tmp_path)
    return tmp_path


@pytest.fixture()
def minimal_repo(tmp_repo: Path) -> Path:
    """
    A repo with all structural checks passing:
    - terraform/versions.tf  (with required_providers for aws and github)
    - terraform/backend.tf   (with s3)
    - .github/CODEOWNERS
    - .github/workflows/{terraform-plan,terraform-apply,compliance-check,pre-publication-audit}.yml
    - terraform/modules/example/{main,variables,outputs}.tf
    """
    # versions.tf
    _write(
        tmp_repo / "terraform" / "versions.tf",
        """\
        terraform {
          required_version = ">= 1.10.0"
          required_providers {
            aws = {
              source  = "hashicorp/aws"
              version = "~> 5.75"
            }
            github = {
              source  = "integrations/github"
              version = "~> 6.3"
            }
          }
        }
        """,
    )

    # backend.tf
    _write(
        tmp_repo / "terraform" / "backend.tf",
        """\
        terraform {
          backend "s3" {
            key = "platform-bootstrap/terraform.tfstate"
          }
        }
        """,
    )

    # CODEOWNERS
    _write(tmp_repo / ".github" / "CODEOWNERS", "* @owner\n")

    # Workflow files
    for wf in [
        "terraform-plan.yml",
        "terraform-apply.yml",
        "compliance-check.yml",
        "pre-publication-audit.yml",
    ]:
        _write(tmp_repo / ".github" / "workflows" / wf, "# placeholder\n")

    # A complete module
    for f in ["main.tf", "variables.tf", "outputs.tf"]:
        _write(tmp_repo / "terraform" / "modules" / "example" / f, "# placeholder\n")

    return tmp_repo


# ---------------------------------------------------------------------------
# VERSIONS_TF_EXISTS
# ---------------------------------------------------------------------------


class TestVersionsTfExists:
    def test_passes_when_file_exists(self, tmp_repo: Path) -> None:
        _write(tmp_repo / "terraform" / "versions.tf", "# ok\n")
        result = _single(cc.check_versions_tf_exists(), "VERSIONS_TF_EXISTS")
        assert result.status == cc.Status.PASS

    def test_fails_when_file_missing(self, tmp_repo: Path) -> None:
        result = _single(cc.check_versions_tf_exists(), "VERSIONS_TF_EXISTS")
        assert result.status == cc.Status.FAIL
        assert "not found" in result.message

    def test_fail_includes_runbook_reference(self, tmp_repo: Path) -> None:
        result = _single(cc.check_versions_tf_exists(), "VERSIONS_TF_EXISTS")
        assert "02-bootstrap.md" in result.runbook
        assert "Prerequisites" in result.runbook


# ---------------------------------------------------------------------------
# VERSIONS_TF_PINS_ALL_PROVIDERS
# ---------------------------------------------------------------------------


class TestVersionsTfPinsAllProviders:
    def test_passes_with_full_required_providers(self, tmp_repo: Path) -> None:
        _write(
            tmp_repo / "terraform" / "versions.tf",
            """\
            terraform {
              required_providers {
                aws = { source = "hashicorp/aws" }
                github = { source = "integrations/github" }
              }
            }
            """,
        )
        result = _single(
            cc.check_versions_tf_pins_all_providers(), "VERSIONS_TF_PINS_ALL_PROVIDERS"
        )
        assert result.status == cc.Status.PASS

    def test_fails_when_file_missing(self, tmp_repo: Path) -> None:
        result = _single(
            cc.check_versions_tf_pins_all_providers(), "VERSIONS_TF_PINS_ALL_PROVIDERS"
        )
        assert result.status == cc.Status.FAIL

    def test_fails_when_required_providers_block_absent(self, tmp_repo: Path) -> None:
        _write(
            tmp_repo / "terraform" / "versions.tf",
            """\
            terraform {
              required_version = ">= 1.10.0"
            }
            """,
        )
        result = _single(
            cc.check_versions_tf_pins_all_providers(), "VERSIONS_TF_PINS_ALL_PROVIDERS"
        )
        assert result.status == cc.Status.FAIL
        assert "required_providers" in result.message

    def test_fails_when_github_missing(self, tmp_repo: Path) -> None:
        _write(
            tmp_repo / "terraform" / "versions.tf",
            """\
            terraform {
              required_providers {
                aws = { source = "hashicorp/aws" }
              }
            }
            """,
        )
        result = _single(
            cc.check_versions_tf_pins_all_providers(), "VERSIONS_TF_PINS_ALL_PROVIDERS"
        )
        assert result.status == cc.Status.FAIL


# ---------------------------------------------------------------------------
# NO_HARDCODED_ACCOUNT_IDS
# ---------------------------------------------------------------------------


class TestNoHardcodedAccountIds:
    def test_passes_when_no_account_ids(self, tmp_repo: Path) -> None:
        _write(
            tmp_repo / "terraform" / "main.tf",
            "resource \"aws_s3_bucket\" \"state\" { bucket = var.bucket_name }\n",
        )
        results = cc.check_no_hardcoded_account_ids()
        assert all(r.status == cc.Status.PASS for r in results)

    def test_warns_on_twelve_digit_number(self, tmp_repo: Path) -> None:
        _write(
            tmp_repo / "terraform" / "main.tf",
            'resource "aws_iam_role" "r" { account = "123456789012" }\n',
        )
        results = cc.check_no_hardcoded_account_ids()
        warns = [r for r in results if r.status == cc.Status.WARN]
        assert warns, "Expected at least one WARN for 12-digit account ID"

    def test_warns_on_multiple_occurrences(self, tmp_repo: Path) -> None:
        _write(
            tmp_repo / "terraform" / "main.tf",
            'arn = "arn:aws:iam::111122223333:role/x"\n'
            'arn2 = "arn:aws:iam::444455556666:role/y"\n',
        )
        results = cc.check_no_hardcoded_account_ids()
        warns = [r for r in results if r.status == cc.Status.WARN]
        assert len(warns) >= 2

    def test_ignores_comment_lines(self, tmp_repo: Path) -> None:
        _write(
            tmp_repo / "terraform" / "main.tf",
            "# account_id = 123456789012\n"
            "resource \"aws_s3_bucket\" \"s\" { bucket = var.b }\n",
        )
        results = cc.check_no_hardcoded_account_ids()
        warns = [r for r in results if r.status == cc.Status.WARN]
        assert not warns, "Should not warn on comment-only occurrences"

    def test_does_not_warn_on_short_numbers(self, tmp_repo: Path) -> None:
        # 11 and 13 digit numbers should not trigger
        _write(
            tmp_repo / "terraform" / "main.tf",
            'value = "12345678901"\nother = "1234567890123"\n',
        )
        results = cc.check_no_hardcoded_account_ids()
        warns = [r for r in results if r.status == cc.Status.WARN]
        assert not warns

    def test_no_tf_files_returns_pass(self, tmp_repo: Path) -> None:
        # No .tf files at all
        results = cc.check_no_hardcoded_account_ids()
        assert all(r.status == cc.Status.PASS for r in results)


# ---------------------------------------------------------------------------
# NO_HARDCODED_REGIONS
# ---------------------------------------------------------------------------


class TestNoHardcodedRegions:
    def test_passes_when_using_variable(self, tmp_repo: Path) -> None:
        _write(
            tmp_repo / "terraform" / "main.tf",
            "provider \"aws\" { region = var.aws_region }\n",
        )
        results = cc.check_no_hardcoded_regions()
        assert all(r.status == cc.Status.PASS for r in results)

    def test_warns_on_hardcoded_region(self, tmp_repo: Path) -> None:
        _write(
            tmp_repo / "terraform" / "main.tf",
            'provider "aws" { region = "us-east-1" }\n',
        )
        results = cc.check_no_hardcoded_regions()
        warns = [r for r in results if r.status == cc.Status.WARN]
        assert warns

    def test_warns_on_eu_region(self, tmp_repo: Path) -> None:
        _write(
            tmp_repo / "terraform" / "variables.tf",
            'variable "region" { default = "eu-west-1" }\n',
        )
        results = cc.check_no_hardcoded_regions()
        warns = [r for r in results if r.status == cc.Status.WARN]
        assert warns


# ---------------------------------------------------------------------------
# NO_HARDCODED_BUCKET_NAMES
# ---------------------------------------------------------------------------


class TestNoHardcodedBucketNames:
    def test_passes_when_using_variable(self, tmp_repo: Path) -> None:
        _write(
            tmp_repo / "terraform" / "main.tf",
            'resource "aws_s3_bucket" "s" { bucket = var.bucket_name }\n',
        )
        results = cc.check_no_hardcoded_bucket_names()
        assert all(r.status == cc.Status.PASS for r in results)

    def test_warns_on_tfstate_literal(self, tmp_repo: Path) -> None:
        _write(
            tmp_repo / "terraform" / "main.tf",
            'resource "aws_s3_bucket" "s" { bucket = "my-tfstate-bucket" }\n',
        )
        results = cc.check_no_hardcoded_bucket_names()
        warns = [r for r in results if r.status == cc.Status.WARN]
        assert warns

    def test_warns_on_terraform_state_literal(self, tmp_repo: Path) -> None:
        _write(
            tmp_repo / "terraform" / "backend.tf",
            'backend "s3" { bucket = "acme-terraform-state" }\n',
        )
        results = cc.check_no_hardcoded_bucket_names()
        warns = [r for r in results if r.status == cc.Status.WARN]
        assert warns

    def test_warns_on_state_bucket_literal(self, tmp_repo: Path) -> None:
        _write(
            tmp_repo / "terraform" / "main.tf",
            'locals { b = "prod-state-bucket-01" }\n',
        )
        results = cc.check_no_hardcoded_bucket_names()
        warns = [r for r in results if r.status == cc.Status.WARN]
        assert warns


# ---------------------------------------------------------------------------
# CODEOWNERS_EXISTS
# ---------------------------------------------------------------------------


class TestCodeownersExists:
    def test_passes_when_file_exists(self, tmp_repo: Path) -> None:
        _write(tmp_repo / ".github" / "CODEOWNERS", "* @owner\n")
        result = _single(cc.check_codeowners_exists(), "CODEOWNERS_EXISTS")
        assert result.status == cc.Status.PASS

    def test_fails_when_missing(self, tmp_repo: Path) -> None:
        result = _single(cc.check_codeowners_exists(), "CODEOWNERS_EXISTS")
        assert result.status == cc.Status.FAIL

    def test_fail_has_runbook_reference(self, tmp_repo: Path) -> None:
        result = _single(cc.check_codeowners_exists(), "CODEOWNERS_EXISTS")
        assert "02-bootstrap.md" in result.runbook


# ---------------------------------------------------------------------------
# MODULES_COMPLETE
# ---------------------------------------------------------------------------


class TestModulesComplete:
    def test_passes_when_all_files_present(self, tmp_repo: Path) -> None:
        for f in ["main.tf", "variables.tf", "outputs.tf"]:
            _write(tmp_repo / "terraform" / "modules" / "mymod" / f, "# ok\n")
        results = cc.check_modules_complete()
        assert all(r.status == cc.Status.PASS for r in results)

    def test_fails_when_outputs_missing(self, tmp_repo: Path) -> None:
        for f in ["main.tf", "variables.tf"]:
            _write(tmp_repo / "terraform" / "modules" / "mymod" / f, "# ok\n")
        results = cc.check_modules_complete()
        fails = [r for r in results if r.status == cc.Status.FAIL]
        assert fails
        assert "outputs.tf" in fails[0].message

    def test_fails_when_variables_missing(self, tmp_repo: Path) -> None:
        for f in ["main.tf", "outputs.tf"]:
            _write(tmp_repo / "terraform" / "modules" / "mymod" / f, "# ok\n")
        results = cc.check_modules_complete()
        fails = [r for r in results if r.status == cc.Status.FAIL]
        assert fails
        assert "variables.tf" in fails[0].message

    def test_fails_when_main_missing(self, tmp_repo: Path) -> None:
        for f in ["variables.tf", "outputs.tf"]:
            _write(tmp_repo / "terraform" / "modules" / "mymod" / f, "# ok\n")
        results = cc.check_modules_complete()
        fails = [r for r in results if r.status == cc.Status.FAIL]
        assert fails
        assert "main.tf" in fails[0].message

    def test_fails_when_modules_dir_missing(self, tmp_repo: Path) -> None:
        results = cc.check_modules_complete()
        fails = [r for r in results if r.status == cc.Status.FAIL]
        assert fails

    def test_multiple_modules_all_complete(self, tmp_repo: Path) -> None:
        for mod in ["mod-a", "mod-b"]:
            for f in ["main.tf", "variables.tf", "outputs.tf"]:
                _write(tmp_repo / "terraform" / "modules" / mod / f, "# ok\n")
        results = cc.check_modules_complete()
        assert all(r.status == cc.Status.PASS for r in results)

    def test_reports_separate_failures_for_each_missing_file(self, tmp_repo: Path) -> None:
        # Only main.tf present — two files missing
        _write(tmp_repo / "terraform" / "modules" / "incomplete" / "main.tf", "# ok\n")
        results = cc.check_modules_complete()
        fails = [r for r in results if r.status == cc.Status.FAIL]
        assert len(fails) == 2

    def test_fail_message_names_specific_module(self, tmp_repo: Path) -> None:
        for f in ["main.tf", "variables.tf"]:
            _write(tmp_repo / "terraform" / "modules" / "oidc-roles" / f, "# ok\n")
        results = cc.check_modules_complete()
        fails = [r for r in results if r.status == cc.Status.FAIL]
        assert any("oidc-roles" in r.message for r in fails)


# ---------------------------------------------------------------------------
# BACKEND_CONFIGURED
# ---------------------------------------------------------------------------


class TestBackendConfigured:
    def test_passes_when_backend_tf_has_s3(self, tmp_repo: Path) -> None:
        _write(
            tmp_repo / "terraform" / "backend.tf",
            'terraform { backend "s3" { key = "foo" } }\n',
        )
        result = _single(cc.check_backend_configured(), "BACKEND_CONFIGURED")
        assert result.status == cc.Status.PASS

    def test_fails_when_file_missing(self, tmp_repo: Path) -> None:
        result = _single(cc.check_backend_configured(), "BACKEND_CONFIGURED")
        assert result.status == cc.Status.FAIL

    def test_fails_when_s3_not_in_file(self, tmp_repo: Path) -> None:
        _write(
            tmp_repo / "terraform" / "backend.tf",
            'terraform { backend "local" { path = "terraform.tfstate" } }\n',
        )
        result = _single(cc.check_backend_configured(), "BACKEND_CONFIGURED")
        assert result.status == cc.Status.FAIL
        assert "s3" in result.message


# ---------------------------------------------------------------------------
# PLATFORM_BOOTSTRAP_NOT_MANAGED
# ---------------------------------------------------------------------------


class TestPlatformBootstrapNotManaged:
    def test_passes_when_no_github_repository_resources(self, tmp_repo: Path) -> None:
        _write(
            tmp_repo / "terraform" / "main.tf",
            'resource "aws_s3_bucket" "s" { bucket = "other" }\n',
        )
        results = cc.check_platform_bootstrap_not_managed()
        assert all(r.status == cc.Status.PASS for r in results)

    def test_passes_when_other_repos_managed(self, tmp_repo: Path) -> None:
        _write(
            tmp_repo / "terraform" / "repos.tf",
            textwrap.dedent("""\
                resource "github_repository" "managed" {
                  for_each = local.repos_map
                  name     = each.value.name
                }
            """),
        )
        results = cc.check_platform_bootstrap_not_managed()
        assert all(r.status == cc.Status.PASS for r in results)

    def test_fails_when_platform_bootstrap_in_github_repository_resource(
        self, tmp_repo: Path
    ) -> None:
        _write(
            tmp_repo / "terraform" / "repos.tf",
            textwrap.dedent("""\
                resource "github_repository" "pb" {
                  name = "platform-bootstrap"
                }
            """),
        )
        results = cc.check_platform_bootstrap_not_managed()
        fails = [r for r in results if r.status == cc.Status.FAIL]
        assert fails

    def test_fail_message_names_the_file(self, tmp_repo: Path) -> None:
        _write(
            tmp_repo / "terraform" / "bad.tf",
            textwrap.dedent("""\
                resource "github_repository" "pb" {
                  name = "platform-bootstrap"
                }
            """),
        )
        results = cc.check_platform_bootstrap_not_managed()
        fails = [r for r in results if r.status == cc.Status.FAIL]
        assert fails
        assert "bad.tf" in fails[0].message

    def test_passes_when_no_tf_files(self, tmp_repo: Path) -> None:
        results = cc.check_platform_bootstrap_not_managed()
        assert all(r.status == cc.Status.PASS for r in results)


# ---------------------------------------------------------------------------
# WORKFLOWS_EXIST
# ---------------------------------------------------------------------------


class TestWorkflowsExist:
    def test_passes_when_all_workflows_present(self, tmp_repo: Path) -> None:
        for wf in [
            "terraform-plan.yml",
            "terraform-apply.yml",
            "compliance-check.yml",
            "pre-publication-audit.yml",
        ]:
            _write(tmp_repo / ".github" / "workflows" / wf, "# ok\n")
        results = cc.check_workflows_exist()
        assert all(r.status == cc.Status.PASS for r in results)

    def test_fails_when_one_workflow_missing(self, tmp_repo: Path) -> None:
        for wf in ["terraform-plan.yml", "terraform-apply.yml", "compliance-check.yml"]:
            _write(tmp_repo / ".github" / "workflows" / wf, "# ok\n")
        # pre-publication-audit.yml is missing
        results = cc.check_workflows_exist()
        fails = [r for r in results if r.status == cc.Status.FAIL]
        assert fails
        assert any("pre-publication-audit.yml" in r.message for r in fails)

    def test_fails_when_all_workflows_missing(self, tmp_repo: Path) -> None:
        results = cc.check_workflows_exist()
        fails = [r for r in results if r.status == cc.Status.FAIL]
        assert len(fails) == len(cc.REQUIRED_WORKFLOW_FILES)

    def test_fails_have_runbook_references(self, tmp_repo: Path) -> None:
        results = cc.check_workflows_exist()
        fails = [r for r in results if r.status == cc.Status.FAIL]
        for fail in fails:
            assert "02-bootstrap.md" in fail.runbook


# ---------------------------------------------------------------------------
# CheckResult dataclass
# ---------------------------------------------------------------------------


class TestCheckResult:
    def test_is_fail(self) -> None:
        r = cc.CheckResult(name="X", status=cc.Status.FAIL, message="oops")
        assert r.is_fail()
        assert not r.is_warn()

    def test_is_warn(self) -> None:
        r = cc.CheckResult(name="X", status=cc.Status.WARN, message="hmm")
        assert r.is_warn()
        assert not r.is_fail()

    def test_needs_detail_for_fail(self) -> None:
        r = cc.CheckResult(name="X", status=cc.Status.FAIL, message="oops")
        assert r.needs_detail()

    def test_needs_detail_for_warn(self) -> None:
        r = cc.CheckResult(name="X", status=cc.Status.WARN, message="hmm")
        assert r.needs_detail()

    def test_no_detail_for_pass(self) -> None:
        r = cc.CheckResult(name="X", status=cc.Status.PASS, message="ok")
        assert not r.needs_detail()


# ---------------------------------------------------------------------------
# format_result output format
# ---------------------------------------------------------------------------


class TestFormatResult:
    def test_pass_format(self) -> None:
        r = cc.CheckResult(name="MY_CHECK", status=cc.Status.PASS, message="looks good")
        output = cc.format_result(r)
        assert output.startswith("[PASS] MY_CHECK: looks good")

    def test_fail_format_includes_detail(self) -> None:
        r = cc.CheckResult(
            name="MY_CHECK",
            status=cc.Status.FAIL,
            message="something broke",
            what_is_wrong="The thing is broken.",
            how_to_fix="Fix it.",
            runbook="See runbook: docs/runbooks/02-bootstrap.md — 'Prerequisites'",
        )
        output = cc.format_result(r)
        assert "[FAIL] MY_CHECK: something broke" in output
        assert "What's wrong: The thing is broken." in output
        assert "How to fix: Fix it." in output
        assert "02-bootstrap.md" in output

    def test_warn_format_includes_detail(self) -> None:
        r = cc.CheckResult(
            name="MY_CHECK",
            status=cc.Status.WARN,
            message="possible issue",
            what_is_wrong="Might be a problem.",
            how_to_fix="Check it.",
            runbook="See runbook: docs/runbooks/02-bootstrap.md — 'Prerequisites'",
        )
        output = cc.format_result(r)
        assert "[WARN] MY_CHECK: possible issue" in output
        assert "What's wrong: Might be a problem." in output

    def test_pass_has_no_detail_section(self) -> None:
        r = cc.CheckResult(name="X", status=cc.Status.PASS, message="ok")
        output = cc.format_result(r)
        assert "What's wrong" not in output
        assert "How to fix" not in output


# ---------------------------------------------------------------------------
# Exit code behaviour via main()
# ---------------------------------------------------------------------------


class TestMainExitCode:
    def test_exit_zero_on_all_pass(self, minimal_repo: Path) -> None:
        exit_code = cc.main(["--structural-only"])
        assert exit_code == 0

    def test_exit_one_when_fail_present(self, tmp_repo: Path) -> None:
        # Missing versions.tf → FAIL → exit 1
        exit_code = cc.main(["--structural-only"])
        assert exit_code == 1

    def test_exit_zero_with_only_warnings(self, tmp_repo: Path) -> None:
        """Warnings alone must not cause a non-zero exit."""
        # Minimal passing repo but with a hardcoded account ID (→ WARN)
        _write(
            tmp_repo / "terraform" / "versions.tf",
            textwrap.dedent("""\
                terraform {
                  required_providers {
                    aws    = { source = "hashicorp/aws" }
                    github = { source = "integrations/github" }
                  }
                }
            """),
        )
        _write(
            tmp_repo / "terraform" / "backend.tf",
            'terraform { backend "s3" { key = "x" } }\n',
        )
        _write(tmp_repo / ".github" / "CODEOWNERS", "* @owner\n")
        for wf in [
            "terraform-plan.yml",
            "terraform-apply.yml",
            "compliance-check.yml",
            "pre-publication-audit.yml",
        ]:
            _write(tmp_repo / ".github" / "workflows" / wf, "# ok\n")
        # Add a file with a WARN-level finding: hardcoded account ID
        _write(
            tmp_repo / "terraform" / "main.tf",
            '# account = "123456789012"\n'  # comment — should NOT warn
            "resource \"aws_s3_bucket\" \"s\" { bucket = var.b }\n",
        )
        # Should be 0 (no FAILs). Modules dir absent is a FAIL — add a complete module.
        for f in ["main.tf", "variables.tf", "outputs.tf"]:
            _write(tmp_repo / "terraform" / "modules" / "m" / f, "# ok\n")

        exit_code = cc.main(["--structural-only"])
        assert exit_code == 0


# ---------------------------------------------------------------------------
# Subprocess integration test
# ---------------------------------------------------------------------------


SCRIPT_PATH = str(_SCRIPTS_DIR / "compliance_check.py")


class TestSubprocessRun:
    def test_structural_only_exits_zero_on_real_repo(self) -> None:
        """
        Run --structural-only against the real repository.
        The repo is fully bootstrapped so all structural checks should pass.
        """
        result = subprocess.run(
            [sys.executable, SCRIPT_PATH, "--structural-only"],
            capture_output=True,
            text=True,
        )
        # Exit code 0 means no FAILs (WARN is ok)
        assert result.returncode == 0, (
            f"Expected exit 0 but got {result.returncode}.\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )

    def test_structural_only_output_has_header(self) -> None:
        result = subprocess.run(
            [sys.executable, SCRIPT_PATH, "--structural-only"],
            capture_output=True,
            text=True,
        )
        assert "=== Platform Bootstrap Compliance Check ===" in result.stdout

    def test_structural_only_output_has_run_at(self) -> None:
        result = subprocess.run(
            [sys.executable, SCRIPT_PATH, "--structural-only"],
            capture_output=True,
            text=True,
        )
        assert "Run at:" in result.stdout

    def test_structural_only_output_has_mode_line(self) -> None:
        result = subprocess.run(
            [sys.executable, SCRIPT_PATH, "--structural-only"],
            capture_output=True,
            text=True,
        )
        assert "Mode: structural" in result.stdout

    def test_structural_only_output_has_summary(self) -> None:
        result = subprocess.run(
            [sys.executable, SCRIPT_PATH, "--structural-only"],
            capture_output=True,
            text=True,
        )
        assert "--- Summary ---" in result.stdout
        assert "PASS:" in result.stdout

    def test_output_lines_have_status_prefix(self) -> None:
        """Every check output line must start with [PASS], [FAIL], or [WARN]."""
        result = subprocess.run(
            [sys.executable, SCRIPT_PATH, "--structural-only"],
            capture_output=True,
            text=True,
        )
        check_lines = [
            line
            for line in result.stdout.splitlines()
            if line.startswith("[")
        ]
        assert check_lines, "Expected at least one [PASS/FAIL/WARN] line"
        for line in check_lines:
            assert line.startswith(("[PASS]", "[FAIL]", "[WARN]")), (
                f"Unexpected prefix on line: {line!r}"
            )

    def test_no_args_same_as_structural_only(self) -> None:
        """Running with no args should produce the same exit code as --structural-only."""
        result_noargs = subprocess.run(
            [sys.executable, SCRIPT_PATH],
            capture_output=True,
            text=True,
        )
        result_explicit = subprocess.run(
            [sys.executable, SCRIPT_PATH, "--structural-only"],
            capture_output=True,
            text=True,
        )
        assert result_noargs.returncode == result_explicit.returncode

    def test_fail_lines_include_remediation(self, tmp_path: Path) -> None:
        """
        Inject a broken repo into a subprocess env by overriding REPO_ROOT
        isn't straightforward; instead synthesise a tiny script that points
        REPO_ROOT at a temp dir missing versions.tf and runs main().
        """
        driver = tmp_path / "driver.py"
        driver.write_text(
            textwrap.dedent(f"""\
                import sys, pathlib
                sys.path.insert(0, {str(_SCRIPTS_DIR)!r})
                import compliance_check as cc
                cc.REPO_ROOT = pathlib.Path({str(tmp_path)!r})
                sys.exit(cc.main(["--structural-only"]))
            """)
        )
        result = subprocess.run(
            [sys.executable, str(driver)],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 1
        # FAIL lines must include remediation guidance
        fail_lines_ctx = []
        lines = result.stdout.splitlines()
        for i, line in enumerate(lines):
            if line.startswith("[FAIL]"):
                # Collect this line + next few lines for context
                fail_lines_ctx.extend(lines[i : i + 6])
        combined = "\n".join(fail_lines_ctx)
        assert "How to fix" in combined or "See runbook" in combined, (
            f"Expected remediation text in FAIL output:\n{result.stdout}"
        )


# ---------------------------------------------------------------------------
# Runbook reference format consistency
# ---------------------------------------------------------------------------


class TestRunbookReferences:
    """All runbook references in check results must use the canonical format."""

    VALID_RUNBOOKS = [
        "docs/runbooks/02-bootstrap.md",
        "docs/runbooks/03-disaster-recovery.md",
    ]

    def _collect_all_structural_results(self, tmp_repo: Path) -> List[cc.CheckResult]:
        """Run all structural checks against an empty tmp repo."""
        return cc.structural_registry.run_all()

    def test_fail_runbook_references_are_canonical(self, tmp_repo: Path) -> None:
        results = self._collect_all_structural_results(tmp_repo)
        for r in results:
            if r.runbook:
                assert any(rb in r.runbook for rb in self.VALID_RUNBOOKS), (
                    f"Check {r.name!r} has non-canonical runbook reference: {r.runbook!r}"
                )

    def test_fail_results_always_have_runbook(self, tmp_repo: Path) -> None:
        results = self._collect_all_structural_results(tmp_repo)
        for r in results:
            if r.status == cc.Status.FAIL:
                assert r.runbook, (
                    f"FAIL result for {r.name!r} is missing a runbook reference"
                )

    def test_warn_results_always_have_runbook(self, tmp_repo: Path) -> None:
        # Add a file with a hardcoded account ID to trigger a WARN
        _write(
            tmp_repo / "terraform" / "main.tf",
            'resource "x" "y" { account_id = "123456789012" }\n',
        )
        results = self._collect_all_structural_results(tmp_repo)
        for r in results:
            if r.status == cc.Status.WARN:
                assert r.runbook, (
                    f"WARN result for {r.name!r} is missing a runbook reference"
                )


# ---------------------------------------------------------------------------
# COMPLIANCE_SCRIPT_SELF_CHECK
# ---------------------------------------------------------------------------


class TestComplianceScriptSelfCheck:
    def test_importable_result_always_passes(self) -> None:
        results = cc.check_compliance_script_self_check()
        importable = [r for r in results if "importable" in r.message]
        assert importable
        assert all(r.status == cc.Status.PASS for r in importable)
