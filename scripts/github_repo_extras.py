#!/usr/bin/env python3
"""Apply GitHub repository settings not supported by the Terraform GitHub provider.

Used from terraform_data local-exec provisioners in terraform/modules/github-repos.
Requires GITHUB_TOKEN (and GITHUB_ORG for owner) in the environment.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

API_VERSION = "2022-11-28"


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
) -> dict:
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


def _repository_node_id(owner: str, name: str) -> str:
    data = _graphql(
        """
        query ($owner: String!, $name: String!) {
          repository(owner: $owner, name: $name) {
            id
            hasDiscussionsEnabled
          }
        }
        """,
        {"owner": owner, "name": name},
    )
    repo = data.get("repository")
    if not repo:
        sys.exit(f"Repository {owner}/{name} not found")
    if not repo.get("hasDiscussionsEnabled"):
        sys.exit(
            f"Discussions are not enabled on {owner}/{name}; "
            "set has_discussions = true on github_repository first"
        )
    return repo["id"]


def _list_category_slugs(owner: str, name: str) -> set[str]:
    data = _graphql(
        """
        query ($owner: String!, $name: String!) {
          repository(owner: $owner, name: $name) {
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
    nodes = data["repository"]["discussionCategories"]["nodes"]
    return {node["slug"] for node in nodes}


def cmd_ensure_discussion_category(args: argparse.Namespace) -> None:
    owner = _org()
    slug = args.slug or args.name.lower().replace(" ", "-")
    existing = _list_category_slugs(owner, args.repo)
    if slug in existing:
        print(f"discussion category {slug!r} already exists on {owner}/{args.repo}")
        return

    repository_id = _repository_node_id(owner, args.repo)
    variables = {
        "input": {
            "repositoryId": repository_id,
            "name": args.name,
            "description": args.description,
        }
    }
    if args.emoji:
        variables["input"]["emoji"] = args.emoji

    data = _graphql(
        """
        mutation ($input: CreateDiscussionCategoryInput!) {
          createDiscussionCategory(input: $input) {
            discussionCategory {
              slug
              name
            }
          }
        }
        """,
        variables,
    )
    created = data["createDiscussionCategory"]["discussionCategory"]
    print(
        f"created discussion category {created['slug']!r} ({created['name']!r}) "
        f"on {owner}/{args.repo}"
    )


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

    cat = sub.add_parser("ensure-discussion-category")
    cat.add_argument("--repo", required=True, help="Repository name (without owner)")
    cat.add_argument("--name", required=True, help="Category display name")
    cat.add_argument("--slug", help="Expected slug (used for idempotency check only)")
    cat.add_argument("--description", default="", help="Category description")
    cat.add_argument("--emoji", default="", help="Optional emoji shortcode, e.g. :bulb:")
    cat.set_defaults(func=cmd_ensure_discussion_category)

    lbl = sub.add_parser("delete-label")
    lbl.add_argument("--repo", required=True)
    lbl.add_argument("--name", required=True, help="Label name to delete")
    lbl.set_defaults(func=cmd_delete_label)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
