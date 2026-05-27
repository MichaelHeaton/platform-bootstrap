#!/usr/bin/env python3
"""GitHub repository extras not supported by the Terraform GitHub provider.

- ensure-default-branch: initialize empty repos and ensure the configured default branch exists
- delete-label: remove labels (used from terraform_data local-exec on apply)
- verify-discussion-categories: check required discussion category slugs exist

Discussion categories cannot be created via the public GitHub GraphQL/REST API.
Custom categories (e.g. mod-suggestions) must be added once in the repo UI.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API_VERSION = "2022-11-28"

# Keep in sync with terraform/pack-*.tf and docs/runbooks/05-specterrealm-pack-github-settings.md
PACK_DISCUSSION_SLUGS: dict[str, list[str]] = {
    "minecraft-modpack-cp-verdant": ["ideas", "mod-suggestions"],
}

SUPPORTED_LICENSES = {"MIT"}


def _token() -> str:
    token = os.environ.get("GITHUB_TOKEN")
    if not token:
        sys.exit("GITHUB_TOKEN is required")
    return token


def _org() -> str:
    org = os.environ.get("GITHUB_ORG")
    if not org:
        sys.exit("GITHUB_ORG is required")
    return org


def _request(
    method: str,
    url: str,
    *,
    data: dict | None = None,
    allow_not_found: bool = False,
) -> dict | None:
    headers = {
        "Authorization": f"Bearer {_token()}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": API_VERSION,
    }
    body = None
    if data is not None:
        headers["Content-Type"] = "application/json"
        body = json.dumps(data).encode()
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")
        if allow_not_found and (
            exc.code == 404 or (exc.code == 409 and "Git Repository is empty" in detail)
        ):
            return None
        sys.exit(f"GitHub API {method} {url} failed ({exc.code}): {detail}")


def _graphql(query: str, variables: dict | None = None) -> dict:
    payload = _request(
        "POST",
        "https://api.github.com/graphql",
        data={"query": query, "variables": variables or {}},
    )
    if payload.get("errors"):
        sys.exit(f"GraphQL errors: {json.dumps(payload['errors'], indent=2)}")
    return payload["data"]


def _repo_url(owner: str, repo: str, suffix: str = "") -> str:
    encoded_owner = urllib.parse.quote(owner, safe="")
    encoded_repo = urllib.parse.quote(repo, safe="")
    return f"https://api.github.com/repos/{encoded_owner}/{encoded_repo}{suffix}"


def _get_branch_ref(owner: str, repo: str, branch: str) -> dict | None:
    encoded_branch = urllib.parse.quote(branch, safe="")
    return _request(
        "GET",
        _repo_url(owner, repo, f"/git/ref/heads/{encoded_branch}"),
        allow_not_found=True,
    )


def _set_default_branch(owner: str, repo: str, branch: str) -> None:
    _request("PATCH", _repo_url(owner, repo), data={"default_branch": branch})


def _license_text(spdx_id: str, copyright_holder: str) -> str:
    normalized = spdx_id.upper()
    if normalized not in SUPPORTED_LICENSES:
        sys.exit(f"Unsupported license SPDX ID: {spdx_id}. Supported: {', '.join(sorted(SUPPORTED_LICENSES))}")

    year = dt.datetime.now(dt.UTC).year
    if normalized == "MIT":
        return f"""MIT License

Copyright (c) {year} {copyright_holder}

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""

    raise AssertionError(f"unhandled supported license: {normalized}")


def _run_git(args: list[str], cwd: Path, *, token: str) -> None:
    result = subprocess.run(
        ["git", *args],
        cwd=cwd,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        return

    output = f"{result.stdout}\n{result.stderr}".replace(token, "[REDACTED]")
    sys.exit(f"git {' '.join(args[:2])} failed:\n{output}")


def _create_initial_branch(
    owner: str,
    repo: str,
    branch: str,
    *,
    codeowners: str,
    license_spdx_id: str = "",
    license_copyright_holder: str = "",
) -> None:
    token = _token()
    encoded_token = urllib.parse.quote(token, safe="")
    encoded_owner = urllib.parse.quote(owner, safe="")
    encoded_repo = urllib.parse.quote(repo, safe="")
    remote = f"https://x-access-token:{encoded_token}@github.com/{encoded_owner}/{encoded_repo}.git"

    with tempfile.TemporaryDirectory(prefix=f"{repo}-init-") as tmp:
        workdir = Path(tmp)
        (workdir / "README.md").write_text(
            f"# {repo}\n\nManaged by platform-bootstrap.\n",
            encoding="utf-8",
        )
        (workdir / "CODEOWNERS").write_text(codeowners, encoding="utf-8")
        if license_spdx_id:
            (workdir / "LICENSE").write_text(
                _license_text(license_spdx_id, license_copyright_holder or owner),
                encoding="utf-8",
            )

        _run_git(["init", "-b", branch], workdir, token=token)
        _run_git(["config", "user.name", "platform-bootstrap"], workdir, token=token)
        _run_git(
            ["config", "user.email", "platform-bootstrap@users.noreply.github.com"],
            workdir,
            token=token,
        )
        initial_files = ["README.md", "CODEOWNERS"]
        if license_spdx_id:
            initial_files.append("LICENSE")
        _run_git(["add", *initial_files], workdir, token=token)
        _run_git(["commit", "-m", "chore: initialize repository"], workdir, token=token)
        _run_git(["push", remote, f"HEAD:refs/heads/{branch}"], workdir, token=token)

    _set_default_branch(owner, repo, branch)


def cmd_ensure_default_branch(args: argparse.Namespace) -> None:
    owner = _org()
    repo_info = _request("GET", _repo_url(owner, args.repo))
    assert repo_info is not None

    desired = args.branch
    desired_ref = _get_branch_ref(owner, args.repo, desired)
    if desired_ref is not None:
        if repo_info.get("default_branch") != desired:
            _set_default_branch(owner, args.repo, desired)
            print(f"set default branch for {owner}/{args.repo} to {desired}")
        else:
            print(f"{owner}/{args.repo}: default branch {desired} already exists")
        return

    current_default = repo_info.get("default_branch")
    current_ref = _get_branch_ref(owner, args.repo, current_default) if current_default else None
    if current_ref is not None:
        _request(
            "POST",
            _repo_url(owner, args.repo, "/git/refs"),
            data={"ref": f"refs/heads/{desired}", "sha": current_ref["object"]["sha"]},
        )
        _set_default_branch(owner, args.repo, desired)
        print(f"created {desired} from {current_default} and set it as default for {owner}/{args.repo}")
        return

    codeowners = f"* {args.codeowners.strip()}\n"
    _create_initial_branch(
        owner,
        args.repo,
        desired,
        codeowners=codeowners,
        license_spdx_id=args.license_spdx_id,
        license_copyright_holder=args.license_copyright_holder,
    )
    print(f"initialized empty repository {owner}/{args.repo} with default branch {desired}")


def _repo_remote(owner: str, repo: str) -> str:
    token = _token()
    encoded_token = urllib.parse.quote(token, safe="")
    encoded_owner = urllib.parse.quote(owner, safe="")
    encoded_repo = urllib.parse.quote(repo, safe="")
    return f"https://x-access-token:{encoded_token}@github.com/{encoded_owner}/{encoded_repo}.git"


def cmd_ensure_license(args: argparse.Namespace) -> None:
    owner = _org()
    branch_ref = _get_branch_ref(owner, args.repo, args.branch)
    if branch_ref is None:
        sys.exit(f"Branch {args.branch} does not exist on {owner}/{args.repo}; run ensure-default-branch first")

    token = _token()
    with tempfile.TemporaryDirectory(prefix=f"{args.repo}-license-") as tmp:
        parent = Path(tmp)
        workdir = parent / args.repo
        _run_git(
            ["clone", "--branch", args.branch, "--depth", "1", _repo_remote(owner, args.repo), str(workdir)],
            parent,
            token=token,
        )

        license_path = workdir / "LICENSE"
        if license_path.exists():
            print(f"{owner}/{args.repo}: LICENSE already exists")
            return

        license_path.write_text(
            _license_text(args.license_spdx_id, args.license_copyright_holder or owner),
            encoding="utf-8",
        )
        _run_git(["add", "LICENSE"], workdir, token=token)
        _run_git(["commit", "-m", "chore: add license"], workdir, token=token)
        _run_git(["push", "origin", f"HEAD:refs/heads/{args.branch}"], workdir, token=token)
        print(f"added {args.license_spdx_id} LICENSE to {owner}/{args.repo}")


def _list_category_slugs(owner: str, name: str) -> set[str]:
    data = _graphql(
        """
        query ($owner: String!, $name: String!) {
          repository(owner: $owner, name: $name) {
            hasDiscussionsEnabled
            discussionCategories(first: 50) {
              nodes {
                slug
              }
            }
          }
        }
        """,
        {"owner": owner, "name": name},
    )
    repo = data.get("repository")
    if not repo:
        sys.exit(f"Repository {owner}/{name} not found")
    if not repo.get("hasDiscussionsEnabled"):
        sys.exit(f"Discussions are not enabled on {owner}/{name}")
    nodes = repo["discussionCategories"]["nodes"]
    return {node["slug"] for node in nodes}


def cmd_verify_discussion_categories(args: argparse.Namespace) -> None:
    owner = _org()
    repos = PACK_DISCUSSION_SLUGS if args.repo is None else {args.repo: PACK_DISCUSSION_SLUGS[args.repo]}
    missing_any = False

    for repo, required_slugs in repos.items():
        if args.repo is not None and repo != args.repo:
            continue
        present = _list_category_slugs(owner, repo)
        missing = [slug for slug in required_slugs if slug not in present]
        if missing:
            missing_any = True
            print(
                f"FAIL {owner}/{repo}: missing discussion categories: {', '.join(missing)}",
                file=sys.stderr,
            )
            print(
                f"  Create in GitHub: Settings → General → Discussions → New category",
                file=sys.stderr,
            )
        else:
            print(f"OK {owner}/{repo}: discussion categories {required_slugs}")

    if missing_any:
        sys.exit(1)


def cmd_delete_label(args: argparse.Namespace) -> None:
    owner = _org()
    encoded = urllib.parse.quote(args.name, safe="")
    url = f"https://api.github.com/repos/{owner}/{args.repo}/labels/{encoded}"
    headers = {
        "Authorization": f"Bearer {_token()}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": API_VERSION,
    }
    req = urllib.request.Request(url, headers=headers, method="DELETE")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            resp.read()
        print(f"deleted label {args.name!r} from {owner}/{args.repo}")
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            print(f"label {args.name!r} not present on {owner}/{args.repo}; skipping")
            return
        detail = exc.read().decode(errors="replace")
        sys.exit(f"GitHub API DELETE {url} failed ({exc.code}): {detail}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    verify = sub.add_parser("verify-discussion-categories")
    verify.add_argument("--repo", help="Single repo name to verify (default: all pack repos)")
    verify.set_defaults(func=cmd_verify_discussion_categories)

    init = sub.add_parser("ensure-default-branch")
    init.add_argument("--repo", required=True)
    init.add_argument("--branch", required=True)
    init.add_argument("--codeowners", required=True, help="Space-delimited CODEOWNERS handles")
    init.add_argument("--license-spdx-id", default="")
    init.add_argument("--license-copyright-holder", default="")
    init.set_defaults(func=cmd_ensure_default_branch)

    lic = sub.add_parser("ensure-license")
    lic.add_argument("--repo", required=True)
    lic.add_argument("--branch", required=True)
    lic.add_argument("--license-spdx-id", required=True)
    lic.add_argument("--license-copyright-holder", required=True)
    lic.set_defaults(func=cmd_ensure_license)

    lbl = sub.add_parser("delete-label")
    lbl.add_argument("--repo", required=True)
    lbl.add_argument("--name", required=True, help="Label name to delete")
    lbl.set_defaults(func=cmd_delete_label)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
