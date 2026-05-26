"""Tests for scripts/github_repo_extras.py."""

from __future__ import annotations

import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import github_repo_extras as extras  # noqa: E402


def test_list_category_slugs_parses_nodes() -> None:
    with patch.object(extras, "_graphql", return_value={
        "repository": {
            "discussionCategories": {
                "nodes": [{"slug": "ideas"}, {"slug": "general"}],
            }
        }
    }):
        assert extras._list_category_slugs("org", "repo") == {"ideas", "general"}


def test_ensure_discussion_category_skips_existing() -> None:
    args = argparse_namespace(
        repo="pack",
        name="Ideas",
        slug="ideas",
        description="x",
        emoji="",
    )
    with (
        patch.object(extras, "_list_category_slugs", return_value={"ideas"}),
        patch.object(extras, "_repository_node_id") as repo_id,
        patch.object(extras, "_graphql") as gql,
    ):
        extras.cmd_ensure_discussion_category(args)
        repo_id.assert_not_called()
        gql.assert_not_called()


def test_delete_label_treats_404_as_success() -> None:
    import urllib.error

    args = argparse_namespace(repo="pack", name="domain/adobe")
    err = urllib.error.HTTPError("url", 404, "nope", hdrs=None, fp=None)
    with (
        patch.dict("os.environ", {"GITHUB_TOKEN": "t", "GITHUB_ORG": "MichaelHeaton"}),
        patch("urllib.request.urlopen", side_effect=err),
    ):
        extras.cmd_delete_label(args)


def argparse_namespace(**kwargs):
    return type("NS", (), kwargs)()
