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


def test_delete_label_treats_404_as_success() -> None:
    import urllib.error

    args = type("NS", (), {"repo": "pack", "name": "domain/adobe"})()
    err = urllib.error.HTTPError("url", 404, "nope", hdrs=None, fp=None)
    with (
        patch.dict("os.environ", {"GITHUB_TOKEN": "t", "GITHUB_ORG": "MichaelHeaton"}),
        patch("urllib.request.urlopen", side_effect=err),
    ):
        extras.cmd_delete_label(args)
