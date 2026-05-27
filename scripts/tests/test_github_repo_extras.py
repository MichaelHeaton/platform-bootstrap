"""Tests for scripts/github_repo_extras.py."""

from __future__ import annotations

import sys
from pathlib import Path
from unittest.mock import patch

import pytest

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
        {"repo": "ai-skills", "branch": "main", "codeowners": "@MichaelHeaton"},
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
        {"repo": "ai-skills", "branch": "main", "codeowners": "@MichaelHeaton"},
    )()
    calls = []

    def fake_request(method: str, url: str, **kwargs: object) -> dict | None:
        calls.append((method, url, kwargs))
        if method == "GET" and url.endswith("/ai-skills"):
            return {"default_branch": "Main"}
        if method == "GET" and "/git/ref/heads/" in url:
            return None
        if method == "POST" and url.endswith("/git/blobs"):
            return {"sha": f"blob-{len(calls)}"}
        if method == "POST" and url.endswith("/git/trees"):
            return {"sha": "tree"}
        if method == "POST" and url.endswith("/git/commits"):
            return {"sha": "commit"}
        if method == "POST" and url.endswith("/git/refs"):
            return {}
        if method == "PATCH" and url.endswith("/ai-skills"):
            return {}
        raise AssertionError(f"unexpected request: {method} {url}")

    with (
        patch.dict("os.environ", {"GITHUB_TOKEN": "t", "GITHUB_ORG": "MichaelHeaton"}),
        patch.object(extras, "_request", side_effect=fake_request),
    ):
        extras.cmd_ensure_default_branch(args)

    tree_call = next(call for call in calls if call[1].endswith("/git/trees"))
    tree_entries = tree_call[2]["data"]["tree"]  # type: ignore[index]
    ref_call = next(call for call in calls if call[1].endswith("/git/refs"))
    patch_call = calls[-1]

    assert [entry["path"] for entry in tree_entries] == ["README.md", "CODEOWNERS"]
    assert ref_call[2]["data"]["ref"] == "refs/heads/main"  # type: ignore[index]
    assert patch_call[0] == "PATCH"
    assert patch_call[2]["data"]["default_branch"] == "main"  # type: ignore[index]


def test_delete_label_treats_404_as_success() -> None:
    import urllib.error

    args = type("NS", (), {"repo": "pack", "name": "domain/adobe"})()
    err = urllib.error.HTTPError("url", 404, "nope", hdrs=None, fp=None)
    with (
        patch.dict("os.environ", {"GITHUB_TOKEN": "t", "GITHUB_ORG": "MichaelHeaton"}),
        patch("urllib.request.urlopen", side_effect=err),
    ):
        extras.cmd_delete_label(args)
