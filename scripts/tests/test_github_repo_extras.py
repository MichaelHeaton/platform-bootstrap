"""Tests for scripts/github_repo_extras.py."""

from __future__ import annotations

import sys
from io import BytesIO
from pathlib import Path
from unittest.mock import patch

import pytest
import urllib.error

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import github_repo_extras as extras  # noqa: E402


def test_list_category_slugs_parses_nodes() -> None:
    with patch.object(extras, "_graphql", return_value={
        "repository": {
            "hasDiscussionsEnabled": True,
            "discussionCategories": {
                "nodes": [{"slug": "ideas"}, {"slug": "general"}],
            },
        }
    }):
        assert extras._list_category_slugs("org", "repo") == {"ideas", "general"}


def test_verify_discussion_categories_fails_when_missing() -> None:
    args = type("NS", (), {"repo": "minecraft-modpack-cp-verdant"})()
    with (
        patch.dict("os.environ", {"GITHUB_TOKEN": "t", "GITHUB_ORG": "MichaelHeaton"}),
        patch.object(extras, "_list_category_slugs", return_value={"ideas"}),
        pytest.raises(SystemExit) as exc,
    ):
        extras.cmd_verify_discussion_categories(args)
    assert exc.value.code == 1


def test_ensure_default_branch_noops_when_branch_exists() -> None:
    args = type(
        "NS",
        (),
        {
            "repo": "ai-skills",
            "branch": "main",
            "codeowners": "@MichaelHeaton",
            "license_spdx_id": "",
            "license_copyright_holder": "",
        },
    )()
    calls = []

    def fake_request(method: str, url: str, **kwargs: object) -> dict | None:
        calls.append((method, url, kwargs))
        if url.endswith("/ai-skills"):
            return {"default_branch": "main"}
        if url.endswith("/git/ref/heads/main"):
            return {"object": {"sha": "abc"}}
        raise AssertionError(f"unexpected request: {method} {url}")

    with (
        patch.dict("os.environ", {"GITHUB_TOKEN": "t", "GITHUB_ORG": "MichaelHeaton"}),
        patch.object(extras, "_request", side_effect=fake_request),
    ):
        extras.cmd_ensure_default_branch(args)

    assert [call[0] for call in calls] == ["GET", "GET"]


def test_ensure_default_branch_initializes_empty_repo() -> None:
    args = type(
        "NS",
        (),
        {
            "repo": "ai-skills",
            "branch": "main",
            "codeowners": "@MichaelHeaton",
            "license_spdx_id": "MIT",
            "license_copyright_holder": "Michael Heaton",
        },
    )()
    api_calls = []
    git_calls = []

    def fake_request(method: str, url: str, **kwargs: object) -> dict | None:
        api_calls.append((method, url, kwargs))
        if method == "GET" and url.endswith("/ai-skills"):
            return {"default_branch": "Main"}
        if method == "GET" and "/git/ref/heads/" in url:
            return None
        if method == "PATCH" and url.endswith("/ai-skills"):
            return {}
        raise AssertionError(f"unexpected request: {method} {url}")

    def fake_run_git(args: list[str], cwd: Path, **kwargs: object) -> None:
        git_calls.append(args)

    with (
        patch.dict("os.environ", {"GITHUB_TOKEN": "t", "GITHUB_ORG": "MichaelHeaton"}),
        patch.object(extras, "_request", side_effect=fake_request),
        patch.object(extras, "_run_git", side_effect=fake_run_git),
    ):
        extras.cmd_ensure_default_branch(args)

    assert git_calls[0] == ["init", "-b", "main"]
    add_call = next(call for call in git_calls if call[0] == "add")
    assert "LICENSE" in add_call
    assert git_calls[-1][0] == "push"
    assert git_calls[-1][-1] == "HEAD:refs/heads/main"
    patch_call = api_calls[-1]
    assert patch_call[0] == "PATCH"
    assert patch_call[2]["data"]["default_branch"] == "main"  # type: ignore[index]


def test_ensure_license_adds_license_when_missing(tmp_path: Path) -> None:
    args = type(
        "NS",
        (),
        {
            "repo": "ai-skills",
            "branch": "main",
            "license_spdx_id": "MIT",
            "license_copyright_holder": "Michael Heaton",
        },
    )()
    git_calls = []

    def fake_run_git(args: list[str], cwd: Path, **kwargs: object) -> None:
        git_calls.append(args)
        if args[0] == "clone":
            clone_target = Path(args[-1])
            clone_target.mkdir(parents=True, exist_ok=True)

    with (
        patch.dict("os.environ", {"GITHUB_TOKEN": "t", "GITHUB_ORG": "MichaelHeaton"}),
        patch.object(extras, "_get_branch_ref", return_value={"object": {"sha": "abc"}}),
        patch.object(extras, "_run_git", side_effect=fake_run_git),
        patch("tempfile.TemporaryDirectory") as tmpdir,
    ):
        tmpdir.return_value.__enter__.return_value = str(tmp_path)
        extras.cmd_ensure_license(args)

    assert any(call[0] == "clone" for call in git_calls)
    assert ["config", "user.name", "platform-bootstrap"] in git_calls
    assert [
        "config",
        "user.email",
        "platform-bootstrap@users.noreply.github.com",
    ] in git_calls
    assert any(call == ["add", "LICENSE"] for call in git_calls)
    assert git_calls[-1] == ["push", "origin", "HEAD:refs/heads/main"]
    assert "MIT License" in (tmp_path / "ai-skills" / "LICENSE").read_text()


def test_get_branch_ref_treats_empty_repo_409_as_missing() -> None:
    err = urllib.error.HTTPError(
        "url",
        409,
        "conflict",
        hdrs=None,
        fp=BytesIO(b'{"message":"Git Repository is empty."}'),
    )

    with (
        patch.dict("os.environ", {"GITHUB_TOKEN": "t", "GITHUB_ORG": "MichaelHeaton"}),
        patch("urllib.request.urlopen", side_effect=err),
    ):
        assert extras._get_branch_ref("MichaelHeaton", "ai-skills", "main") is None


def test_delete_label_treats_404_as_success() -> None:
    args = type("NS", (), {"repo": "pack", "name": "domain/adobe"})()
    err = urllib.error.HTTPError("url", 404, "nope", hdrs=None, fp=None)
    with (
        patch.dict("os.environ", {"GITHUB_TOKEN": "t", "GITHUB_ORG": "MichaelHeaton"}),
        patch("urllib.request.urlopen", side_effect=err),
    ):
        extras.cmd_delete_label(args)
