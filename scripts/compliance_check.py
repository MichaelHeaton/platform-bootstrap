#!/usr/bin/env python3
"""
compliance_check.py — drift detection for platform-bootstrap.

Read-only. Compares actual infrastructure state against expected configuration.

Usage:
    python scripts/compliance_check.py                   # structural checks only
    python scripts/compliance_check.py --structural-only # explicit structural-only
    python scripts/compliance_check.py \
        --account-id 123456789012 \
        --region us-east-1 \
        --bucket my-bucket \
        --github-org myorg                               # full checks

Exit codes:
    0 — all checks PASS or WARN
    1 — at least one FAIL
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, List, Optional

# ---------------------------------------------------------------------------
# Optional heavy dependencies — degrade gracefully when absent.
# ---------------------------------------------------------------------------
try:
    import boto3  # type: ignore
    import botocore.exceptions  # type: ignore

    BOTO3_AVAILABLE = True
except ImportError:
    BOTO3_AVAILABLE = False

try:
    import requests  # type: ignore

    REQUESTS_AVAILABLE = True
except ImportError:
    REQUESTS_AVAILABLE = False

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

REPO_ROOT: Path = Path(__file__).resolve().parent.parent

REQUIRED_WORKFLOW_FILES = [
    ".github/workflows/terraform-plan.yml",
    ".github/workflows/terraform-apply.yml",
    ".github/workflows/compliance-check.yml",
    ".github/workflows/pre-publication-audit.yml",
]

REQUIRED_MODULE_FILES = ["main.tf", "variables.tf", "outputs.tf"]

HARDCODED_REGIONS = [
    "us-east-1",
    "us-east-2",
    "us-west-1",
    "us-west-2",
    "eu-west-1",
    "eu-west-2",
    "eu-west-3",
    "eu-central-1",
    "eu-north-1",
    "ap-southeast-1",
    "ap-southeast-2",
    "ap-northeast-1",
    "ap-northeast-2",
    "ap-south-1",
    "ca-central-1",
    "sa-east-1",
    "af-south-1",
    "me-south-1",
]

# Bucket name heuristics — literals in .tf files that look like state buckets.
# Patterns intentionally exclude strings containing "/" so that state key paths
# like "platform-bootstrap/terraform.tfstate" are not flagged as bucket names.
# S3 bucket names cannot contain forward slashes.
BUCKET_NAME_PATTERNS = [
    r'"[^"/]*tfstate[^"/]*"',
    r'"[^"/]*terraform-state[^"/]*"',
    r'"[^"/]*state-bucket[^"/]*"',
]

REQUIRED_IAM_TAGS = {"environment", "cloud", "function", "managed-by"}

# ---------------------------------------------------------------------------
# Data types
# ---------------------------------------------------------------------------


class Status:
    PASS = "PASS"
    FAIL = "FAIL"
    WARN = "WARN"


@dataclass
class CheckResult:
    name: str
    status: str  # Status.PASS | Status.FAIL | Status.WARN
    message: str
    what_is_wrong: str = ""
    how_to_fix: str = ""
    runbook: str = ""

    def is_fail(self) -> bool:
        return self.status == Status.FAIL

    def is_warn(self) -> bool:
        return self.status == Status.WARN

    def needs_detail(self) -> bool:
        return self.status in (Status.FAIL, Status.WARN)


@dataclass
class CheckRegistry:
    """Ordered list of (label, callable) pairs."""

    _entries: List[tuple[str, Callable[[], List[CheckResult]]]] = field(
        default_factory=list
    )

    def register(self, label: str):
        """Decorator that registers a check function under a label."""

        def decorator(fn: Callable[[], List[CheckResult]]):
            self._entries.append((label, fn))
            return fn

        return decorator

    def run_all(self) -> List[CheckResult]:
        results: List[CheckResult] = []
        for _label, fn in self._entries:
            results.extend(fn())
        return results


# ---------------------------------------------------------------------------
# Helper utilities
# ---------------------------------------------------------------------------


def _tf_files() -> List[Path]:
    """Return all .tf files under terraform/."""
    tf_dir = REPO_ROOT / "terraform"
    if not tf_dir.exists():
        return []
    return list(tf_dir.rglob("*.tf"))


def _pass(name: str, message: str) -> CheckResult:
    return CheckResult(name=name, status=Status.PASS, message=message)


def _fail(
    name: str,
    message: str,
    what_is_wrong: str = "",
    how_to_fix: str = "",
    runbook: str = "",
) -> CheckResult:
    return CheckResult(
        name=name,
        status=Status.FAIL,
        message=message,
        what_is_wrong=what_is_wrong,
        how_to_fix=how_to_fix,
        runbook=runbook,
    )


def _warn(
    name: str,
    message: str,
    what_is_wrong: str = "",
    how_to_fix: str = "",
    runbook: str = "",
) -> CheckResult:
    return CheckResult(
        name=name,
        status=Status.WARN,
        message=message,
        what_is_wrong=what_is_wrong,
        how_to_fix=how_to_fix,
        runbook=runbook,
    )


# ---------------------------------------------------------------------------
# Structural checks (no credentials needed)
# ---------------------------------------------------------------------------

structural_registry = CheckRegistry()


@structural_registry.register("VERSIONS_TF_EXISTS")
def check_versions_tf_exists() -> List[CheckResult]:
    name = "VERSIONS_TF_EXISTS"
    path = REPO_ROOT / "terraform" / "versions.tf"
    if path.exists():
        return [_pass(name, "terraform/versions.tf found")]
    return [
        _fail(
            name,
            "terraform/versions.tf not found",
            what_is_wrong="The versions.tf file is missing. Provider version pins are required to prevent unexpected upgrades.",
            how_to_fix="Create terraform/versions.tf with a terraform block containing required_providers for aws and github.",
            runbook="See runbook: docs/runbooks/02-bootstrap.md — 'Prerequisites'",
        )
    ]


@structural_registry.register("VERSIONS_TF_PINS_ALL_PROVIDERS")
def check_versions_tf_pins_all_providers() -> List[CheckResult]:
    name = "VERSIONS_TF_PINS_ALL_PROVIDERS"
    path = REPO_ROOT / "terraform" / "versions.tf"
    if not path.exists():
        return [
            _fail(
                name,
                "terraform/versions.tf not found — cannot check provider pins",
                what_is_wrong="versions.tf is missing entirely; provider pins cannot be verified.",
                how_to_fix="Create terraform/versions.tf with required_providers block including aws and github.",
                runbook="See runbook: docs/runbooks/02-bootstrap.md — 'Prerequisites'",
            )
        ]
    content = path.read_text()
    missing = []
    if "required_providers" not in content:
        missing.append("required_providers block")
    if '"hashicorp/aws"' not in content and "aws" not in content:
        missing.append("aws provider")
    else:
        # Verify aws appears in required_providers context
        if not re.search(r'aws\s*=\s*\{', content):
            missing.append("aws provider block")
    if "github" not in content:
        missing.append("github provider")
    else:
        if not re.search(r'github\s*=\s*\{', content):
            missing.append("github provider block")

    if missing:
        return [
            _fail(
                name,
                f"versions.tf is missing: {', '.join(missing)}",
                what_is_wrong=f"versions.tf does not pin all required providers. Missing: {', '.join(missing)}.",
                how_to_fix="Add required_providers blocks for both aws (hashicorp/aws) and github (integrations/github) with version constraints.",
                runbook="See runbook: docs/runbooks/02-bootstrap.md — 'Prerequisites'",
            )
        ]
    return [_pass(name, "versions.tf contains required_providers with aws and github")]


@structural_registry.register("NO_HARDCODED_ACCOUNT_IDS")
def check_no_hardcoded_account_ids() -> List[CheckResult]:
    name = "NO_HARDCODED_ACCOUNT_IDS"
    account_id_re = re.compile(r'\b(\d{12})\b')
    findings: List[str] = []

    for tf_file in _tf_files():
        try:
            content = tf_file.read_text()
        except OSError:
            continue
        for lineno, line in enumerate(content.splitlines(), start=1):
            # Skip comment lines
            stripped = line.strip()
            if stripped.startswith("#"):
                continue
            matches = account_id_re.findall(line)
            if matches:
                rel = tf_file.relative_to(REPO_ROOT)
                findings.append(f"{rel}:{lineno} — {line.strip()!r}")

    if not findings:
        return [_pass(name, "No hardcoded 12-digit AWS account IDs found in .tf files")]

    results = []
    for finding in findings:
        results.append(
            _warn(
                name,
                f"Potential hardcoded AWS account ID in {finding}",
                what_is_wrong="Hardcoded 12-digit account IDs make it impossible to reuse Terraform config across accounts and expose account information in version control.",
                how_to_fix="Replace the hardcoded account ID with var.aws_account_id.",
                runbook="See runbook: docs/runbooks/02-bootstrap.md — 'Prerequisites'",
            )
        )
    return results


@structural_registry.register("NO_HARDCODED_REGIONS")
def check_no_hardcoded_regions() -> List[CheckResult]:
    name = "NO_HARDCODED_REGIONS"
    findings: List[str] = []

    # Build a regex that matches any known region as a quoted string literal.
    region_pattern = re.compile(
        r'"(' + "|".join(re.escape(r) for r in HARDCODED_REGIONS) + r')"'
    )

    for tf_file in _tf_files():
        try:
            content = tf_file.read_text()
        except OSError:
            continue
        for lineno, line in enumerate(content.splitlines(), start=1):
            stripped = line.strip()
            if stripped.startswith("#"):
                continue
            if region_pattern.search(line):
                rel = tf_file.relative_to(REPO_ROOT)
                findings.append(f"{rel}:{lineno}")

    if not findings:
        return [_pass(name, "No hardcoded AWS region strings found in .tf files")]

    results = []
    for finding in findings:
        results.append(
            _warn(
                name,
                f"Found potential hardcoded region in {finding}",
                what_is_wrong="Hardcoded region values prevent reuse across different environments and make multi-region deployments difficult.",
                how_to_fix="Replace with var.aws_region.",
                runbook="See runbook: docs/runbooks/02-bootstrap.md — 'Prerequisites'",
            )
        )
    return results


@structural_registry.register("NO_HARDCODED_BUCKET_NAMES")
def check_no_hardcoded_bucket_names() -> List[CheckResult]:
    name = "NO_HARDCODED_BUCKET_NAMES"
    findings: List[str] = []

    combined_re = re.compile(
        "|".join(BUCKET_NAME_PATTERNS), re.IGNORECASE
    )

    for tf_file in _tf_files():
        try:
            content = tf_file.read_text()
        except OSError:
            continue
        for lineno, line in enumerate(content.splitlines(), start=1):
            stripped = line.strip()
            if stripped.startswith("#"):
                continue
            if combined_re.search(line):
                rel = tf_file.relative_to(REPO_ROOT)
                findings.append(f"{rel}:{lineno}")

    if not findings:
        return [
            _pass(name, "No hardcoded state bucket name literals found in .tf files")
        ]

    results = []
    for finding in findings:
        results.append(
            _warn(
                name,
                f"Found potential hardcoded bucket name in {finding}",
                what_is_wrong="Hardcoded bucket names prevent reuse and can leak internal naming conventions.",
                how_to_fix="Replace with var.state_bucket_name.",
                runbook="See runbook: docs/runbooks/02-bootstrap.md — 'Prerequisites'",
            )
        )
    return results


@structural_registry.register("CODEOWNERS_EXISTS")
def check_codeowners_exists() -> List[CheckResult]:
    name = "CODEOWNERS_EXISTS"
    path = REPO_ROOT / ".github" / "CODEOWNERS"
    if path.exists():
        return [_pass(name, ".github/CODEOWNERS found")]
    return [
        _fail(
            name,
            ".github/CODEOWNERS not found",
            what_is_wrong="CODEOWNERS is missing. Without it, GitHub cannot enforce mandatory code review by designated owners.",
            how_to_fix="Create .github/CODEOWNERS with at least one catch-all rule: `* @your-handle`",
            runbook="See runbook: docs/runbooks/02-bootstrap.md — 'Prerequisites'",
        )
    ]


@structural_registry.register("MODULES_COMPLETE")
def check_modules_complete() -> List[CheckResult]:
    name = "MODULES_COMPLETE"
    modules_dir = REPO_ROOT / "terraform" / "modules"
    if not modules_dir.exists():
        return [
            _fail(
                name,
                "terraform/modules/ directory not found",
                what_is_wrong="The terraform/modules/ directory is missing entirely.",
                how_to_fix="Create terraform/modules/ and populate it with the required module directories.",
                runbook="See runbook: docs/runbooks/02-bootstrap.md — 'Prerequisites'",
            )
        ]

    results: List[CheckResult] = []
    module_dirs = [d for d in modules_dir.iterdir() if d.is_dir()]

    if not module_dirs:
        return [_pass(name, "No modules found in terraform/modules/ — nothing to check")]

    for module_dir in sorted(module_dirs):
        for required_file in REQUIRED_MODULE_FILES:
            file_path = module_dir / required_file
            if not file_path.exists():
                rel_module = module_dir.relative_to(REPO_ROOT)
                results.append(
                    _fail(
                        name,
                        f"terraform/modules/{module_dir.name} is missing {required_file}",
                        what_is_wrong=f"The {module_dir.name} module is missing required file {required_file}.",
                        how_to_fix=f"Create {rel_module}/{required_file}",
                        runbook="See runbook: docs/runbooks/02-bootstrap.md — 'Prerequisites'",
                    )
                )

    if not results:
        return [
            _pass(
                name,
                f"All {len(module_dirs)} module(s) have main.tf, variables.tf, and outputs.tf",
            )
        ]
    return results


@structural_registry.register("BACKEND_CONFIGURED")
def check_backend_configured() -> List[CheckResult]:
    name = "BACKEND_CONFIGURED"
    path = REPO_ROOT / "terraform" / "backend.tf"
    if not path.exists():
        return [
            _fail(
                name,
                "terraform/backend.tf not found",
                what_is_wrong="backend.tf is missing. Without it Terraform will default to local state, which is not safe for team use.",
                how_to_fix='Create terraform/backend.tf with a terraform { backend "s3" { ... } } block.',
                runbook="See runbook: docs/runbooks/02-bootstrap.md — 'Create the S3 bootstrap bucket'",
            )
        ]
    content = path.read_text()
    if "s3" not in content:
        return [
            _fail(
                name,
                "terraform/backend.tf exists but does not reference s3",
                what_is_wrong='backend.tf does not contain an s3 backend configuration.',
                how_to_fix='Add backend "s3" {} block to terraform/backend.tf.',
                runbook="See runbook: docs/runbooks/02-bootstrap.md — 'Create the S3 bootstrap bucket'",
            )
        ]
    return [_pass(name, "terraform/backend.tf found and references s3")]


@structural_registry.register("PLATFORM_BOOTSTRAP_NOT_MANAGED")
def check_platform_bootstrap_not_managed() -> List[CheckResult]:
    name = "PLATFORM_BOOTSTRAP_NOT_MANAGED"
    # Look for github_repository resources with name = "platform-bootstrap"
    pattern = re.compile(
        r'resource\s+"github_repository"[^{]*\{[^}]*name\s*=\s*"platform-bootstrap"',
        re.DOTALL,
    )
    # Also the simpler direct assignment form
    simple_pattern = re.compile(r'name\s*=\s*"platform-bootstrap"')

    findings: List[str] = []
    for tf_file in _tf_files():
        try:
            content = tf_file.read_text()
        except OSError:
            continue
        # Check for pattern: inside a github_repository resource block
        # We look for the simpler signal — any github_repository block combined
        # with the literal name value in the same file is a strong indicator.
        if "github_repository" in content and simple_pattern.search(content):
            rel = tf_file.relative_to(REPO_ROOT)
            findings.append(str(rel))
        elif pattern.search(content):
            rel = tf_file.relative_to(REPO_ROOT)
            if str(rel) not in findings:
                findings.append(str(rel))

    if not findings:
        return [
            _pass(
                name,
                'No github_repository resource with name = "platform-bootstrap" found',
            )
        ]
    return [
        _fail(
            name,
            f'Found name = "platform-bootstrap" in a github_repository resource: {", ".join(findings)}',
            what_is_wrong='platform-bootstrap is the bootstrap repo itself and must NOT be managed by Terraform. Managing it creates a circular dependency that can permanently lock the team out of infrastructure.',
            how_to_fix='Remove platform-bootstrap from the managed_repositories variable and from any github_repository resource. See ADR-004.',
            runbook="See runbook: docs/runbooks/02-bootstrap.md — 'Prerequisites'",
        )
    ]


@structural_registry.register("WORKFLOWS_EXIST")
def check_workflows_exist() -> List[CheckResult]:
    name = "WORKFLOWS_EXIST"
    results: List[CheckResult] = []
    for workflow_rel in REQUIRED_WORKFLOW_FILES:
        workflow_path = REPO_ROOT / workflow_rel
        if workflow_path.exists():
            results.append(_pass(name, f"{workflow_rel} found"))
        else:
            results.append(
                _fail(
                    name,
                    f"{workflow_rel} not found",
                    what_is_wrong=f"Required workflow file {workflow_rel} is missing. CI/CD pipelines will not run as expected.",
                    how_to_fix=f"Create {workflow_rel} with the appropriate workflow definition.",
                    runbook="See runbook: docs/runbooks/02-bootstrap.md — 'Verify everything is working'",
                )
            )
    return results


@structural_registry.register("COMPLIANCE_SCRIPT_SELF_CHECK")
def check_compliance_script_self_check() -> List[CheckResult]:
    name = "COMPLIANCE_SCRIPT_SELF_CHECK"
    script_path = Path(__file__).resolve()
    results: List[CheckResult] = []

    # Check executable bit
    if os.access(script_path, os.X_OK):
        results.append(_pass(name, f"{script_path.name} is executable"))
    else:
        results.append(
            _warn(
                name,
                f"{script_path.name} is not executable",
                what_is_wrong="The compliance script does not have the executable bit set, which means it cannot be invoked directly as ./scripts/compliance_check.py.",
                how_to_fix=f"Run: chmod +x {script_path}",
                runbook="See runbook: docs/runbooks/02-bootstrap.md — 'Prerequisites'",
            )
        )

    # Check importability — if we got here, the import succeeded.
    results.append(_pass(name, f"{script_path.name} is importable (running now)"))
    return results


# ---------------------------------------------------------------------------
# Full checks — AWS via boto3
# ---------------------------------------------------------------------------


def _boto3_client(service: str, region: str):
    if not BOTO3_AVAILABLE:
        raise RuntimeError("boto3 is not installed")
    return boto3.client(service, region_name=region)


def check_s3_versioning_enabled(bucket: str, region: str) -> CheckResult:
    name = "S3_VERSIONING_ENABLED"
    try:
        s3 = _boto3_client("s3", region)
        resp = s3.get_bucket_versioning(Bucket=bucket)
        status = resp.get("Status", "")
        if status == "Enabled":
            return _pass(name, f"Bucket {bucket} has versioning enabled")
        return _fail(
            name,
            f"Bucket {bucket} versioning status: {status or 'not configured'}",
            what_is_wrong=f"S3 bucket {bucket} does not have versioning enabled. Without versioning, previous state files cannot be recovered after accidental deletion or corruption.",
            how_to_fix=f"Enable versioning on the bucket: aws s3api put-bucket-versioning --bucket {bucket} --versioning-configuration Status=Enabled",
            runbook="See runbook: docs/runbooks/02-bootstrap.md — 'Create the S3 bootstrap bucket'",
        )
    except Exception as exc:
        return _fail(
            name,
            f"Could not check versioning for {bucket}: {exc}",
            what_is_wrong=f"Failed to query versioning status for bucket {bucket}.",
            how_to_fix="Verify AWS credentials are valid and the bucket exists.",
            runbook="See runbook: docs/runbooks/03-disaster-recovery.md — 'Decision Tree'",
        )


def check_s3_public_access_blocked(bucket: str, region: str) -> CheckResult:
    name = "S3_PUBLIC_ACCESS_BLOCKED"
    try:
        s3 = _boto3_client("s3", region)
        resp = s3.get_public_access_block(Bucket=bucket)
        config = resp.get("PublicAccessBlockConfiguration", {})
        required_keys = [
            "BlockPublicAcls",
            "IgnorePublicAcls",
            "BlockPublicPolicy",
            "RestrictPublicBuckets",
        ]
        not_blocked = [k for k in required_keys if not config.get(k, False)]
        if not not_blocked:
            return _pass(
                name, f"Bucket {bucket} has all four public access block settings enabled"
            )
        return _fail(
            name,
            f"Bucket {bucket} missing public access blocks: {', '.join(not_blocked)}",
            what_is_wrong=f"The following public access block settings are not enabled on {bucket}: {', '.join(not_blocked)}. This could allow public exposure of Terraform state.",
            how_to_fix=f"Run: aws s3api put-public-access-block --bucket {bucket} --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true",
            runbook="See runbook: docs/runbooks/02-bootstrap.md — 'Create the S3 bootstrap bucket'",
        )
    except Exception as exc:
        return _fail(
            name,
            f"Could not check public access block for {bucket}: {exc}",
            what_is_wrong=f"Failed to query public access block configuration for {bucket}.",
            how_to_fix="Verify AWS credentials and that the bucket exists.",
            runbook="See runbook: docs/runbooks/03-disaster-recovery.md — 'Decision Tree'",
        )


def check_s3_encryption_enabled(bucket: str, region: str) -> CheckResult:
    name = "S3_ENCRYPTION_ENABLED"
    try:
        s3 = _boto3_client("s3", region)
        resp = s3.get_bucket_encryption(Bucket=bucket)
        rules = (
            resp.get("ServerSideEncryptionConfiguration", {}).get("Rules", [])
        )
        if rules:
            algo = (
                rules[0]
                .get("ApplyServerSideEncryptionByDefault", {})
                .get("SSEAlgorithm", "unknown")
            )
            return _pass(
                name,
                f"Bucket {bucket} has server-side encryption enabled (algorithm: {algo})",
            )
        return _fail(
            name,
            f"Bucket {bucket} has no server-side encryption rules configured",
            what_is_wrong=f"S3 bucket {bucket} does not have server-side encryption enabled. Terraform state may contain secrets.",
            how_to_fix=f"Enable SSE-S3 encryption: aws s3api put-bucket-encryption --bucket {bucket} --server-side-encryption-configuration '{{\"Rules\":[{{\"ApplyServerSideEncryptionByDefault\":{{\"SSEAlgorithm\":\"AES256\"}},\"BucketKeyEnabled\":true}}]}}'",
            runbook="See runbook: docs/runbooks/02-bootstrap.md — 'Create the S3 bootstrap bucket'",
        )
    except Exception as exc:
        # NoSuchEncryptionConfiguration means encryption is not set
        exc_str = str(exc)
        if "NoSuchEncryptionConfiguration" in exc_str or "ServerSideEncryptionConfigurationNotFoundError" in exc_str:
            return _fail(
                name,
                f"Bucket {bucket} has no server-side encryption configured",
                what_is_wrong=f"S3 bucket {bucket} has no server-side encryption configuration.",
                how_to_fix=f"Enable SSE-S3 encryption on the bucket.",
                runbook="See runbook: docs/runbooks/02-bootstrap.md — 'Create the S3 bootstrap bucket'",
            )
        return _fail(
            name,
            f"Could not check encryption for {bucket}: {exc}",
            what_is_wrong=f"Failed to query encryption configuration for {bucket}.",
            how_to_fix="Verify AWS credentials and that the bucket exists.",
            runbook="See runbook: docs/runbooks/03-disaster-recovery.md — 'Decision Tree'",
        )


def check_s3_https_only_policy(bucket: str, region: str) -> CheckResult:
    name = "S3_HTTPS_ONLY_POLICY"
    import json

    try:
        s3 = _boto3_client("s3", region)
        resp = s3.get_bucket_policy(Bucket=bucket)
        policy_str = resp.get("Policy", "{}")
        policy = json.loads(policy_str)
        statements = policy.get("Statement", [])

        # Look for a Deny statement with aws:SecureTransport = false
        found_deny = False
        for stmt in statements:
            if stmt.get("Effect") != "Deny":
                continue
            condition = stmt.get("Condition", {})
            bool_cond = condition.get("Bool", {})
            # Values may be boolean False or string "false"
            secure_transport = bool_cond.get("aws:SecureTransport")
            if secure_transport in (False, "false"):
                found_deny = True
                break

        if found_deny:
            return _pass(
                name,
                f"Bucket {bucket} policy has Deny for aws:SecureTransport=false (HTTPS-only)",
            )
        return _fail(
            name,
            f"Bucket {bucket} policy does not have a Deny for aws:SecureTransport=false",
            what_is_wrong=f"The bucket policy on {bucket} does not enforce HTTPS-only access. Without this, state files could be transmitted unencrypted.",
            how_to_fix="Add a Deny statement with Condition Bool aws:SecureTransport false to the bucket policy.",
            runbook="See runbook: docs/runbooks/02-bootstrap.md — 'Create the S3 bootstrap bucket'",
        )
    except Exception as exc:
        exc_str = str(exc)
        if "NoSuchBucketPolicy" in exc_str:
            return _fail(
                name,
                f"Bucket {bucket} has no bucket policy",
                what_is_wrong=f"S3 bucket {bucket} has no bucket policy. A policy denying non-HTTPS access is required.",
                how_to_fix="Attach a bucket policy that denies s3:* when aws:SecureTransport is false.",
                runbook="See runbook: docs/runbooks/02-bootstrap.md — 'Create the S3 bootstrap bucket'",
            )
        return _fail(
            name,
            f"Could not check bucket policy for {bucket}: {exc}",
            what_is_wrong=f"Failed to retrieve bucket policy for {bucket}.",
            how_to_fix="Verify AWS credentials and that the bucket exists.",
            runbook="See runbook: docs/runbooks/03-disaster-recovery.md — 'Decision Tree'",
        )


def check_iam_no_wildcard_paths(region: str) -> List[CheckResult]:
    """
    For each IAM role with 'github-actions' in the name, check attached
    managed policies for Resource: '*'. A path ending in /* on a specific
    prefix (e.g. arn:aws:s3:::bucket/prefix/*) is allowed; a bare '*' is not.
    """
    import json

    name = "IAM_NO_WILDCARD_PATHS"
    results: List[CheckResult] = []

    try:
        iam = _boto3_client("iam", region)
        paginator = iam.get_paginator("list_roles")
        github_roles = []
        for page in paginator.paginate():
            for role in page["Roles"]:
                if "github-actions" in role["RoleName"]:
                    github_roles.append(role["RoleName"])

        if not github_roles:
            return [
                _warn(
                    name,
                    "No IAM roles with 'github-actions' in the name found",
                    what_is_wrong="Expected at least one IAM role with 'github-actions' in the name for OIDC federation.",
                    how_to_fix="Create the IAM roles for GitHub Actions OIDC using Terraform.",
                    runbook="See runbook: docs/runbooks/02-bootstrap.md — 'Create the initial IAM role'",
                )
            ]

        for role_name in github_roles:
            # Check attached managed policies
            attached = iam.list_attached_role_policies(RoleName=role_name)
            for policy_summary in attached.get("AttachedPolicies", []):
                policy_arn = policy_summary["PolicyArn"]
                policy_detail = iam.get_policy(PolicyArn=policy_arn)
                version_id = policy_detail["Policy"]["DefaultVersionId"]
                version = iam.get_policy_version(
                    PolicyArn=policy_arn, VersionId=version_id
                )
                doc = version["PolicyVersion"]["Document"]
                statements = doc.get("Statement", [])
                for stmt in statements:
                    resources = stmt.get("Resource", [])
                    if isinstance(resources, str):
                        resources = [resources]
                    for resource in resources:
                        # Bare wildcard is not allowed
                        if resource == "*":
                            results.append(
                                _fail(
                                    name,
                                    f"Role {role_name} policy {policy_summary['PolicyName']} has Resource: '*'",
                                    what_is_wrong=f"Policy {policy_summary['PolicyName']} attached to {role_name} uses Resource: '*', granting access to all AWS resources.",
                                    how_to_fix="Replace Resource: '*' with specific ARNs. See the oidc-roles module for the correct pattern.",
                                    runbook="See runbook: docs/runbooks/02-bootstrap.md — 'Create the initial IAM role'",
                                )
                            )

            # Check inline policies
            inline_policies = iam.list_role_policies(RoleName=role_name)
            for policy_name in inline_policies.get("PolicyNames", []):
                inline = iam.get_role_policy(
                    RoleName=role_name, PolicyName=policy_name
                )
                doc = inline.get("PolicyDocument", {})
                if isinstance(doc, str):
                    doc = json.loads(doc)
                statements = doc.get("Statement", [])
                for stmt in statements:
                    resources = stmt.get("Resource", [])
                    if isinstance(resources, str):
                        resources = [resources]
                    for resource in resources:
                        if resource == "*":
                            results.append(
                                _fail(
                                    name,
                                    f"Role {role_name} inline policy {policy_name} has Resource: '*'",
                                    what_is_wrong=f"Inline policy {policy_name} on {role_name} uses Resource: '*'.",
                                    how_to_fix="Replace with specific ARNs scoped to required resources.",
                                    runbook="See runbook: docs/runbooks/02-bootstrap.md — 'Create the initial IAM role'",
                                )
                            )

        if not results:
            role_list = ", ".join(github_roles)
            return [
                _pass(
                    name,
                    f"No wildcard Resource: '*' found in policies for roles: {role_list}",
                )
            ]
        return results

    except Exception as exc:
        return [
            _fail(
                name,
                f"Could not check IAM policies: {exc}",
                what_is_wrong="Failed to query IAM roles and policies.",
                how_to_fix="Verify AWS credentials have iam:ListRoles, iam:ListAttachedRolePolicies, iam:GetPolicy permissions.",
                runbook="See runbook: docs/runbooks/03-disaster-recovery.md — 'Decision Tree'",
            )
        ]


def check_iam_roles_tagged(region: str) -> List[CheckResult]:
    name = "IAM_ROLES_TAGGED"
    results: List[CheckResult] = []

    try:
        iam = _boto3_client("iam", region)
        paginator = iam.get_paginator("list_roles")
        platform_roles = []
        for page in paginator.paginate():
            for role in page["Roles"]:
                role_name = role["RoleName"]
                # Platform roles are those created by Terraform (github-actions roles)
                if "github-actions" in role_name:
                    platform_roles.append(role)

        if not platform_roles:
            return [
                _warn(
                    name,
                    "No platform IAM roles found to check tags on",
                    what_is_wrong="No IAM roles with 'github-actions' in the name were found.",
                    how_to_fix="Create platform IAM roles using the oidc-roles Terraform module.",
                    runbook="See runbook: docs/runbooks/02-bootstrap.md — 'Create the initial IAM role'",
                )
            ]

        for role in platform_roles:
            role_name = role["RoleName"]
            tags_resp = iam.list_role_tags(RoleName=role_name)
            tag_keys = {t["Key"] for t in tags_resp.get("Tags", [])}
            missing_tags = REQUIRED_IAM_TAGS - tag_keys
            if missing_tags:
                results.append(
                    _fail(
                        name,
                        f"Role {role_name} is missing required tags: {', '.join(sorted(missing_tags))}",
                        what_is_wrong=f"IAM role {role_name} is missing required tags: {', '.join(sorted(missing_tags))}. Tags are required for cost allocation and access audits.",
                        how_to_fix=f"Add missing tags to {role_name}: {', '.join(sorted(missing_tags))}. These are managed via Terraform in the oidc-roles module.",
                        runbook="See runbook: docs/runbooks/02-bootstrap.md — 'Create the initial IAM role'",
                    )
                )
            else:
                results.append(
                    _pass(name, f"Role {role_name} has all required tags")
                )

        return results

    except Exception as exc:
        return [
            _fail(
                name,
                f"Could not check IAM role tags: {exc}",
                what_is_wrong="Failed to query IAM role tags.",
                how_to_fix="Verify AWS credentials have iam:ListRoles, iam:ListRoleTags permissions.",
                runbook="See runbook: docs/runbooks/03-disaster-recovery.md — 'Decision Tree'",
            )
        ]


# ---------------------------------------------------------------------------
# Full checks — GitHub via requests
# ---------------------------------------------------------------------------


def _github_api(path: str, token: str) -> dict | list:
    """Make a GitHub API GET request. Returns parsed JSON."""
    if not REQUESTS_AVAILABLE:
        raise RuntimeError("requests library is not installed")
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    url = f"https://api.github.com{path}"
    resp = requests.get(url, headers=headers, timeout=15)
    resp.raise_for_status()
    return resp.json()


def _list_org_repos(org: str, token: str) -> List[dict]:
    """Return all non-platform-bootstrap repos in the org."""
    repos = []
    page = 1
    while True:
        batch = _github_api(f"/orgs/{org}/repos?per_page=100&page={page}", token)
        if not isinstance(batch, list) or not batch:
            break
        repos.extend(batch)
        if len(batch) < 100:
            break
        page += 1
    return [r for r in repos if r.get("name") != "platform-bootstrap"]


def check_repos_have_branch_protection(org: str, token: str) -> List[CheckResult]:
    name = "REPOS_HAVE_BRANCH_PROTECTION"
    results: List[CheckResult] = []
    try:
        repos = _list_org_repos(org, token)
        if not repos:
            return [_warn(name, f"No managed repos found in org {org} (excluding platform-bootstrap)")]

        for repo in repos:
            repo_name = repo["name"]
            default_branch = repo.get("default_branch", "main")
            try:
                _github_api(
                    f"/repos/{org}/{repo_name}/branches/{default_branch}/protection",
                    token,
                )
                results.append(
                    _pass(name, f"{repo_name}: branch protection on {default_branch} is configured")
                )
            except Exception as exc:
                exc_str = str(exc)
                if "404" in exc_str or "Branch not protected" in exc_str:
                    results.append(
                        _fail(
                            name,
                            f"{repo_name}: no branch protection on {default_branch}",
                            what_is_wrong=f"Repository {repo_name} does not have branch protection on {default_branch}. Direct pushes to the default branch are not prevented.",
                            how_to_fix=f"Add {repo_name} to the managed_repositories variable in Terraform so branch protection is applied via the github-repos module.",
                            runbook="See runbook: docs/runbooks/02-bootstrap.md — 'Verify everything is working'",
                        )
                    )
                else:
                    results.append(
                        _fail(
                            name,
                            f"{repo_name}: could not check branch protection: {exc}",
                            what_is_wrong=f"Failed to query branch protection for {repo_name}/{default_branch}.",
                            how_to_fix="Verify the GitHub token has repo read permissions.",
                            runbook="See runbook: docs/runbooks/03-disaster-recovery.md — 'Decision Tree'",
                        )
                    )
        return results
    except Exception as exc:
        return [
            _fail(
                name,
                f"Could not list repos for org {org}: {exc}",
                what_is_wrong="Failed to query GitHub organization repositories.",
                how_to_fix="Verify the GITHUB_TOKEN has read:org and repo scope.",
                runbook="See runbook: docs/runbooks/03-disaster-recovery.md — 'Decision Tree'",
            )
        ]


def check_repos_have_secret_scanning(org: str, token: str) -> List[CheckResult]:
    name = "REPOS_HAVE_SECRET_SCANNING"
    results: List[CheckResult] = []
    try:
        repos = _list_org_repos(org, token)
        if not repos:
            return [_warn(name, f"No managed repos found in org {org}")]

        for repo in repos:
            repo_name = repo["name"]
            security = repo.get("security_and_analysis", {}) or {}
            ss = security.get("secret_scanning", {}) or {}
            status = ss.get("status", "disabled")
            if status == "enabled":
                results.append(_pass(name, f"{repo_name}: secret scanning is enabled"))
            else:
                results.append(
                    _fail(
                        name,
                        f"{repo_name}: secret scanning is {status}",
                        what_is_wrong=f"Repository {repo_name} does not have secret scanning enabled. Secrets committed to the repo will not be detected.",
                        how_to_fix=f"Add {repo_name} to managed_repositories in Terraform — the github-repos module enables secret scanning automatically.",
                        runbook="See runbook: docs/runbooks/02-bootstrap.md — 'Verify everything is working'",
                    )
                )
        return results
    except Exception as exc:
        return [
            _fail(
                name,
                f"Could not check secret scanning for org {org}: {exc}",
                what_is_wrong="Failed to query repository secret scanning status.",
                how_to_fix="Verify the GITHUB_TOKEN has repo read permissions.",
                runbook="See runbook: docs/runbooks/03-disaster-recovery.md — 'Decision Tree'",
            )
        ]


def check_repos_have_push_protection(org: str, token: str) -> List[CheckResult]:
    name = "REPOS_HAVE_PUSH_PROTECTION"
    results: List[CheckResult] = []
    try:
        repos = _list_org_repos(org, token)
        if not repos:
            return [_warn(name, f"No managed repos found in org {org}")]

        for repo in repos:
            repo_name = repo["name"]
            security = repo.get("security_and_analysis", {}) or {}
            pp = security.get("secret_scanning_push_protection", {}) or {}
            status = pp.get("status", "disabled")
            if status == "enabled":
                results.append(
                    _pass(name, f"{repo_name}: secret scanning push protection is enabled")
                )
            else:
                results.append(
                    _fail(
                        name,
                        f"{repo_name}: secret scanning push protection is {status}",
                        what_is_wrong=f"Repository {repo_name} does not have secret scanning push protection enabled. Commits containing secrets will not be blocked at push time.",
                        how_to_fix=f"Add {repo_name} to managed_repositories in Terraform — the github-repos module enables push protection automatically.",
                        runbook="See runbook: docs/runbooks/02-bootstrap.md — 'Verify everything is working'",
                    )
                )
        return results
    except Exception as exc:
        return [
            _fail(
                name,
                f"Could not check push protection for org {org}: {exc}",
                what_is_wrong="Failed to query repository push protection status.",
                how_to_fix="Verify the GITHUB_TOKEN has repo read permissions.",
                runbook="See runbook: docs/runbooks/03-disaster-recovery.md — 'Decision Tree'",
            )
        ]


def check_repos_have_codeowners(org: str, token: str) -> List[CheckResult]:
    name = "REPOS_HAVE_CODEOWNERS"
    results: List[CheckResult] = []
    codeowners_locations = ["CODEOWNERS", ".github/CODEOWNERS", "docs/CODEOWNERS"]

    try:
        repos = _list_org_repos(org, token)
        if not repos:
            return [_warn(name, f"No managed repos found in org {org}")]

        for repo in repos:
            repo_name = repo["name"]
            found = False
            for loc in codeowners_locations:
                try:
                    _github_api(
                        f"/repos/{org}/{repo_name}/contents/{loc}", token
                    )
                    results.append(
                        _pass(name, f"{repo_name}: CODEOWNERS found at {loc}")
                    )
                    found = True
                    break
                except Exception:
                    pass

            if not found:
                results.append(
                    _fail(
                        name,
                        f"{repo_name}: no CODEOWNERS file found in root, .github/, or docs/",
                        what_is_wrong=f"Repository {repo_name} has no CODEOWNERS file. Without it, GitHub cannot enforce mandatory code review by designated owners.",
                        how_to_fix=f"Add {repo_name} to managed_repositories in Terraform — the github-repos module creates CODEOWNERS automatically.",
                        runbook="See runbook: docs/runbooks/02-bootstrap.md — 'Verify everything is working'",
                    )
                )
        return results
    except Exception as exc:
        return [
            _fail(
                name,
                f"Could not check CODEOWNERS for org {org}: {exc}",
                what_is_wrong="Failed to query repository contents for CODEOWNERS.",
                how_to_fix="Verify the GITHUB_TOKEN has repo read permissions.",
                runbook="See runbook: docs/runbooks/03-disaster-recovery.md — 'Decision Tree'",
            )
        ]


# ---------------------------------------------------------------------------
# Output formatting
# ---------------------------------------------------------------------------

_INDENT = "       "


def format_result(result: CheckResult) -> str:
    lines = [f"[{result.status}] {result.name}: {result.message}"]
    if result.needs_detail():
        if result.what_is_wrong:
            lines.append(f"{_INDENT}What's wrong: {result.what_is_wrong}")
        if result.how_to_fix:
            lines.append(f"{_INDENT}How to fix: {result.how_to_fix}")
        if result.runbook:
            lines.append(f"{_INDENT}{result.runbook}")
    return "\n".join(lines)


def print_results(
    results: List[CheckResult],
    mode: str,
    account_id: Optional[str] = None,
    region: Optional[str] = None,
    bucket: Optional[str] = None,
    github_org: Optional[str] = None,
) -> int:
    """Print all results to stdout. Returns 1 if any FAIL, else 0."""
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    print("=== Platform Bootstrap Compliance Check ===")
    print(f"Run at: {now}")
    print(f"Mode: {mode}")
    if mode == "full":
        if account_id:
            print(f"Account: {account_id}")
        if region:
            print(f"Region: {region}")
        if bucket:
            print(f"Bucket: {bucket}")
        if github_org:
            print(f"GitHub org: {github_org}")

    structural_results = [r for r in results if _is_structural(r)]
    full_results = [r for r in results if not _is_structural(r)]

    if structural_results:
        print("\n--- Structural Checks ---")
        for r in structural_results:
            print(format_result(r))

    if full_results:
        print("\n--- Full Checks ---")
        for r in full_results:
            print(format_result(r))

    pass_count = sum(1 for r in results if r.status == Status.PASS)
    warn_count = sum(1 for r in results if r.status == Status.WARN)
    fail_count = sum(1 for r in results if r.status == Status.FAIL)

    print(f"\n--- Summary ---")
    print(f"PASS: {pass_count}  WARN: {warn_count}  FAIL: {fail_count}")

    exit_code = 1 if fail_count > 0 else 0
    status_label = "FAIL detected" if exit_code else "all checks passed or warned"
    print(f"\nExit code: {exit_code} ({status_label})")
    return exit_code


# Structural check names for classification.
_STRUCTURAL_CHECK_NAMES = {
    "VERSIONS_TF_EXISTS",
    "VERSIONS_TF_PINS_ALL_PROVIDERS",
    "NO_HARDCODED_ACCOUNT_IDS",
    "NO_HARDCODED_REGIONS",
    "NO_HARDCODED_BUCKET_NAMES",
    "CODEOWNERS_EXISTS",
    "MODULES_COMPLETE",
    "BACKEND_CONFIGURED",
    "PLATFORM_BOOTSTRAP_NOT_MANAGED",
    "WORKFLOWS_EXIST",
    "COMPLIANCE_SCRIPT_SELF_CHECK",
}


def _is_structural(result: CheckResult) -> bool:
    return result.name in _STRUCTURAL_CHECK_NAMES


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Platform bootstrap compliance checker (read-only drift detection).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "--structural-only",
        action="store_true",
        help="Run only structural checks (no AWS or GitHub credentials needed).",
    )
    parser.add_argument(
        "--account-id",
        metavar="ACCOUNT_ID",
        help="AWS account ID (12 digits). Required for full checks.",
    )
    parser.add_argument(
        "--region",
        metavar="REGION",
        help="AWS region (e.g. us-east-1). Required for full checks.",
    )
    parser.add_argument(
        "--bucket",
        metavar="BUCKET",
        help="Terraform state S3 bucket name. Required for full checks.",
    )
    parser.add_argument(
        "--github-org",
        metavar="ORG",
        help="GitHub organization name. Required for GitHub checks.",
    )
    return parser


def run_structural_checks() -> List[CheckResult]:
    return structural_registry.run_all()


def run_full_checks(
    account_id: str,
    region: str,
    bucket: str,
    github_org: Optional[str] = None,
) -> List[CheckResult]:
    results: List[CheckResult] = []

    if not BOTO3_AVAILABLE:
        results.append(
            _fail(
                "AWS_CHECKS",
                "boto3 is not installed — AWS checks cannot run",
                what_is_wrong="boto3 is required for AWS checks but is not installed.",
                how_to_fix="Install it: pip install boto3",
                runbook="See runbook: docs/runbooks/02-bootstrap.md — 'Prerequisites'",
            )
        )
    else:
        results.append(check_s3_versioning_enabled(bucket, region))
        results.append(check_s3_public_access_blocked(bucket, region))
        results.append(check_s3_encryption_enabled(bucket, region))
        results.append(check_s3_https_only_policy(bucket, region))
        results.extend(check_iam_no_wildcard_paths(region))
        results.extend(check_iam_roles_tagged(region))

    if github_org:
        github_token = os.environ.get("GITHUB_TOKEN", "")
        if not github_token:
            results.append(
                _fail(
                    "GITHUB_CHECKS",
                    "GITHUB_TOKEN environment variable is not set — GitHub checks cannot run",
                    what_is_wrong="The GITHUB_TOKEN environment variable is required for GitHub checks.",
                    how_to_fix="Set GITHUB_TOKEN to a personal access token or GitHub Actions token with repo read scope.",
                    runbook="See runbook: docs/runbooks/02-bootstrap.md — 'Prerequisites'",
                )
            )
        elif not REQUESTS_AVAILABLE:
            results.append(
                _fail(
                    "GITHUB_CHECKS",
                    "requests library is not installed — GitHub checks cannot run",
                    what_is_wrong="The requests library is required for GitHub API calls.",
                    how_to_fix="Install it: pip install requests",
                    runbook="See runbook: docs/runbooks/02-bootstrap.md — 'Prerequisites'",
                )
            )
        else:
            results.extend(check_repos_have_branch_protection(github_org, github_token))
            results.extend(check_repos_have_secret_scanning(github_org, github_token))
            results.extend(check_repos_have_push_protection(github_org, github_token))
            results.extend(check_repos_have_codeowners(github_org, github_token))

    return results


def main(argv: Optional[List[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    # Determine mode
    has_aws = args.account_id and args.region and args.bucket
    structural_only = args.structural_only or not has_aws

    all_results: List[CheckResult] = run_structural_checks()

    if not structural_only:
        assert args.account_id and args.region and args.bucket  # narrowed above
        all_results.extend(
            run_full_checks(
                account_id=args.account_id,
                region=args.region,
                bucket=args.bucket,
                github_org=args.github_org,
            )
        )

    mode = "structural" if structural_only else "full"
    return print_results(
        all_results,
        mode=mode,
        account_id=args.account_id,
        region=args.region,
        bucket=args.bucket,
        github_org=args.github_org,
    )


if __name__ == "__main__":
    sys.exit(main())
