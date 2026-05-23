#!/usr/bin/env python3
"""
Migrate open issues from a GitLab group to corresponding GitHub repos.

Usage:
    GITLAB_TOKEN=<token> python3 scripts/migrate-gitlab-issues.py [--dry-run]

Requirements:
    - GITLAB_TOKEN env var with read_api scope
    - gh CLI installed and authenticated (gh auth login)
    - python3 with standard library only (no extra packages)

The script maps GitLab project paths under a group to GitHub repos under a GitHub org.
Projects not found in the mapping are skipped with a warning.
Existing GitHub issues with matching migration markers are not duplicated on re-run.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.request
import urllib.parse
from datetime import datetime, timezone

# ── Configuration ─────────────────────────────────────────────────────────────

GITLAB_BASE_URL = "https://gitlab.com"
GITLAB_GROUP = "specterrealm"  # source group namespace
GITHUB_ORG = "MichaelHeaton"   # destination GitHub org

# Map GitLab project path (within the group) to GitHub repo name.
# Add entries here if auto-detection is insufficient.
REPO_MAP_OVERRIDES: dict[str, str] = {}

# Label to add to all migrated issues so they can be identified.
MIGRATION_LABEL = "migrated-from-gitlab"

# Marker embedded in issue body to detect already-migrated issues on re-runs.
MIGRATION_MARKER_PREFIX = "<!-- gitlab-migration:"


# ── GitLab API helpers ────────────────────────────────────────────────────────

def gitlab_get(path: str, token: str, params: dict | None = None) -> list | dict:
    url = f"{GITLAB_BASE_URL}/api/v4/{path}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"PRIVATE-TOKEN": token})
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())


def gitlab_paginate(path: str, token: str, params: dict | None = None) -> list:
    """Fetch all pages from a GitLab list endpoint."""
    results = []
    page = 1
    base_params = dict(params or {})
    base_params["per_page"] = 100
    while True:
        base_params["page"] = page
        page_data = gitlab_get(path, token, base_params)
        if not page_data:
            break
        results.extend(page_data)
        if len(page_data) < 100:
            break
        page += 1
    return results


def get_group_id(group: str, token: str) -> int:
    data = gitlab_get(f"groups/{urllib.parse.quote(group, safe='')}", token)
    return data["id"]


def get_group_projects(group_id: int, token: str) -> list[dict]:
    return gitlab_paginate(
        f"groups/{group_id}/projects",
        token,
        {"include_subgroups": "false", "archived": "false"},
    )


def get_project_issues(project_id: int, token: str) -> list[dict]:
    return gitlab_paginate(
        f"projects/{project_id}/issues",
        token,
        {"state": "opened", "scope": "all"},
    )


def get_issue_notes(project_id: int, issue_iid: int, token: str) -> list[dict]:
    return gitlab_paginate(
        f"projects/{project_id}/issues/{issue_iid}/notes",
        token,
        {"sort": "asc"},
    )


# ── GitHub helpers ────────────────────────────────────────────────────────────

def gh(*args: str) -> dict | list | str:
    """Run a gh CLI command and return parsed JSON or raw string."""
    cmd = ["gh", *args]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"gh command failed: {' '.join(cmd)}\n{result.stderr}")
    out = result.stdout.strip()
    if out.startswith(("{", "[")):
        return json.loads(out)
    return out


def github_repo_exists(repo: str) -> bool:
    try:
        gh("repo", "view", repo, "--json", "name")
        return True
    except RuntimeError:
        return False


def get_existing_issue_markers(repo: str) -> set[str]:
    """Return set of gitlab issue web URLs already migrated to this GitHub repo."""
    try:
        issues = gh(
            "issue", "list",
            "--repo", repo,
            "--state", "all",
            "--limit", "500",
            "--json", "body",
        )
        markers = set()
        for issue in issues:
            body = issue.get("body") or ""
            match = re.search(
                rf"{re.escape(MIGRATION_MARKER_PREFIX)}(https://gitlab\.com[^\s]+) -->",
                body,
            )
            if match:
                markers.add(match.group(1))
        return markers
    except RuntimeError:
        return set()


def ensure_label(repo: str, label: str, color: str = "e11d48", dry_run: bool = False) -> None:
    if dry_run:
        return
    try:
        gh("label", "create", label,
           "--repo", repo,
           "--color", color,
           "--force")
    except RuntimeError:
        pass  # label may already exist; --force handles most cases


def create_github_issue(
    repo: str,
    title: str,
    body: str,
    labels: list[str],
    dry_run: bool,
) -> str | None:
    """Create an issue and return its URL, or None on dry-run."""
    label_args = []
    for label in labels:
        label_args += ["--label", label]

    if dry_run:
        print(f"    [dry-run] Would create issue: {title!r}")
        return None

    result = gh(
        "issue", "create",
        "--repo", repo,
        "--title", title,
        "--body", body,
        *label_args,
    )
    return str(result).strip()


# ── Mapping ───────────────────────────────────────────────────────────────────

def gitlab_path_to_github_repo(gl_path: str) -> str:
    """
    Derive a GitHub repo name from a GitLab project path.
    GitLab path is the part after the group, e.g. 'my-project'.
    Returns 'GITHUB_ORG/repo-name'.
    """
    if gl_path in REPO_MAP_OVERRIDES:
        return f"{GITHUB_ORG}/{REPO_MAP_OVERRIDES[gl_path]}"
    return f"{GITHUB_ORG}/{gl_path}"


# ── Body formatting ───────────────────────────────────────────────────────────

def format_issue_body(gl_issue: dict, notes: list[dict], gl_project_path: str) -> str:
    author = gl_issue.get("author", {}).get("name", "Unknown")
    created_at = gl_issue.get("created_at", "")
    try:
        dt = datetime.fromisoformat(created_at.replace("Z", "+00:00"))
        created_str = dt.strftime("%Y-%m-%d")
    except (ValueError, AttributeError):
        created_str = created_at

    gl_url = gl_issue.get("web_url", "")
    description = gl_issue.get("description") or ""

    lines = [
        f"{MIGRATION_MARKER_PREFIX}{gl_url} -->",
        "",
        f"> **Migrated from GitLab** | Originally opened by **{author}** on {created_str}",
        f"> Source: {gl_url}",
        "",
    ]

    if description.strip():
        lines += [description, ""]

    # Append non-system comments as a collapsible section
    user_notes = [
        n for n in notes
        if not n.get("system", False) and n.get("body", "").strip()
    ]
    if user_notes:
        lines += ["---", "", "<details>", "<summary>Comments from GitLab</summary>", ""]
        for note in user_notes:
            note_author = note.get("author", {}).get("name", "Unknown")
            note_created = note.get("created_at", "")
            try:
                nd = datetime.fromisoformat(note_created.replace("Z", "+00:00"))
                note_date = nd.strftime("%Y-%m-%d")
            except (ValueError, AttributeError):
                note_date = note_created
            lines += [
                f"**{note_author}** ({note_date}):",
                "",
                note.get("body", "").strip(),
                "",
            ]
        lines += ["</details>", ""]

    return "\n".join(lines)


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(description="Migrate GitLab group issues to GitHub")
    parser.add_argument("--dry-run", action="store_true", help="Print actions without creating issues")
    parser.add_argument("--project", help="Migrate only this GitLab project path (within group)")
    args = parser.parse_args()

    token = os.environ.get("GITLAB_TOKEN")
    if not token:
        print("ERROR: GITLAB_TOKEN environment variable not set", file=sys.stderr)
        return 1

    dry_run = args.dry_run
    if dry_run:
        print("=== DRY RUN — no issues will be created ===\n")

    print(f"Fetching projects in GitLab group '{GITLAB_GROUP}'...")
    group_id = get_group_id(GITLAB_GROUP, token)
    projects = get_group_projects(group_id, token)
    print(f"Found {len(projects)} projects\n")

    stats = {"migrated": 0, "skipped_dup": 0, "skipped_no_repo": 0, "errors": 0}

    for project in projects:
        gl_path = project["path"]  # repo slug within the group
        gl_full_path = project["path_with_namespace"]

        if args.project and gl_path != args.project:
            continue

        gh_repo = gitlab_path_to_github_repo(gl_path)

        print(f"── {gl_full_path} → {gh_repo}")

        if not github_repo_exists(gh_repo):
            print(f"   SKIP: GitHub repo {gh_repo} not found\n")
            stats["skipped_no_repo"] += 1
            continue

        issues = get_project_issues(project["id"], token)
        if not issues:
            print(f"   No open issues.\n")
            continue

        print(f"   {len(issues)} open issue(s)")

        existing_markers = get_existing_issue_markers(gh_repo)
        if not dry_run:
            ensure_label(gh_repo, MIGRATION_LABEL)

        for issue in issues:
            gl_url = issue.get("web_url", "")
            title = issue.get("title", "(no title)")

            if gl_url in existing_markers:
                print(f"   → SKIP (already migrated): {title!r}")
                stats["skipped_dup"] += 1
                continue

            # Gather labels: original GitLab labels + migration label
            labels = [lbl for lbl in (issue.get("labels") or []) if lbl]
            labels.append(MIGRATION_LABEL)

            # Create missing labels on GitHub (best-effort)
            if not dry_run:
                for lbl in labels[:-1]:  # skip MIGRATION_LABEL (ensured above)
                    try:
                        gh("label", "create", lbl,
                           "--repo", gh_repo,
                           "--color", "0075ca",
                           "--force")
                    except RuntimeError:
                        pass

            notes = get_issue_notes(project["id"], issue["iid"], token)
            body = format_issue_body(issue, notes, gl_path)

            try:
                url = create_github_issue(gh_repo, title, body, labels, dry_run)
                if url:
                    print(f"   ✓ Created: {title!r} → {url}")
                    stats["migrated"] += 1
                else:
                    print(f"   ✓ [dry-run] {title!r}")
                    stats["migrated"] += 1
            except RuntimeError as exc:
                print(f"   ✗ ERROR creating {title!r}: {exc}", file=sys.stderr)
                stats["errors"] += 1

        print()

    print("── Summary ──────────────────────────────────────────────")
    print(f"  Migrated:         {stats['migrated']}")
    print(f"  Already migrated: {stats['skipped_dup']}")
    print(f"  Repo not found:   {stats['skipped_no_repo']}")
    print(f"  Errors:           {stats['errors']}")

    return 1 if stats["errors"] else 0


if __name__ == "__main__":
    sys.exit(main())
