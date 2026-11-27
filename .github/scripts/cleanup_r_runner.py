#!/usr/bin/env python3
"""Delete ghcr.io/nflverse/r-runner images nobody needs any more.

Every image is three package versions: a tagged index plus two untagged
children (the amd64 image and the build attestation). Deleting a child breaks
the image, so this script decides per image and never deletes anything an
image it keeps refers to.

Kept:
  - latest and candidate
  - test-pr-<n> while PR n is open, test-<branch> while the branch exists
  - besides latest, the newest KEEP_PROMOTED promoted images (date or commit
    SHA tags): the rollback targets
  - images with tags this script doesn't know (to be safe)
Deleted:
  - every other tagged image, with its children
  - untagged versions no kept image refers to, once they are a day old (a
    running build pushes children before their index)

Env: GH_TOKEN (packages write), KEEP_PROMOTED (default 8), DRY_RUN=true to
only print the plan. Stops before deleting anything if a manifest of a kept
or dropped image can't be read.
"""

import json
import os
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

ORG = "nflverse"
PACKAGE = "r-runner"
REPO = os.environ.get("GITHUB_REPOSITORY", "nflverse/actions")
KEEP_PROMOTED = int(os.environ.get("KEEP_PROMOTED", "8"))
DRY_RUN = os.environ.get("DRY_RUN", "false") == "true"
TOKEN = os.environ["GH_TOKEN"]

SHA = re.compile(r"^[0-9a-f]{40}$")
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
TEST_PR = re.compile(r"^test-pr-(\d+)$")
MANIFEST_TYPES = ", ".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])


def github(path, method="GET"):
    """GitHub REST API. Follows pagination for lists, None for 404."""
    url, items = f"https://api.github.com{path}", []
    while url:
        request = urllib.request.Request(url, method=method, headers={
            "Authorization": f"Bearer {TOKEN}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        })
        try:
            with urllib.request.urlopen(request) as response:
                body = response.read()
                link = response.headers.get("Link", "")
        except urllib.error.HTTPError as e:
            if e.code == 404 and method == "GET":
                return None
            raise
        if method != "GET":
            return None
        data = json.loads(body)
        if not isinstance(data, list):
            return data
        items += data
        match = re.search(r'<([^>]+)>;\s*rel="next"', link)
        url = match.group(1) if match else None
    return items


def registry_token():
    url = f"https://ghcr.io/token?scope=repository:{ORG}/{PACKAGE}:pull"
    with urllib.request.urlopen(url) as response:
        return json.load(response)["token"]


def children(digest, token):
    """Digests an index refers to, [] for a plain manifest."""
    request = urllib.request.Request(
        f"https://ghcr.io/v2/{ORG}/{PACKAGE}/manifests/{digest}",
        headers={"Authorization": f"Bearer {token}", "Accept": MANIFEST_TYPES},
    )
    with urllib.request.urlopen(request) as response:
        manifest = json.load(response)
    return [m["digest"] for m in manifest.get("manifests", [])]


def sanitize(branch):
    # same as the Tags step in build-r-runner.yaml
    return re.sub(r"[^a-zA-Z0-9_.-]", "-", branch)


def test_tag_alive(tag, branches):
    match = TEST_PR.match(tag)
    if match:
        pr = github(f"/repos/{REPO}/pulls/{match.group(1)}")
        return pr is not None and pr["state"] == "open"
    return tag[len("test-"):] in branches


def main():
    versions = github(f"/orgs/{ORG}/packages/container/{PACKAGE}/versions?per_page=100")
    branches = {sanitize(b["name"]) for b in github(f"/repos/{REPO}/branches?per_page=100")}
    now = datetime.now(timezone.utc)

    keep, drop = {}, {}  # digest -> (version, reason)
    promoted = []
    for v in versions:
        tags = v["metadata"]["container"]["tags"]
        if not tags:
            continue
        label = ",".join(tags)
        if {"latest", "candidate"} & set(tags):
            keep[v["name"]] = (v, "latest/candidate")
        elif all(t.startswith("test-") for t in tags):
            if any(test_tag_alive(t, branches) for t in tags):
                keep[v["name"]] = (v, "test tag of an open PR or existing branch")
            else:
                drop[v["name"]] = (v, "test tag of a closed PR or deleted branch")
        elif all(SHA.match(t) or DATE.match(t) for t in tags):
            promoted.append(v)
        else:
            keep[v["name"]] = (v, f"unknown tags {label}, kept to be safe")

    promoted.sort(key=lambda v: v["created_at"], reverse=True)
    for i, v in enumerate(promoted):
        if i < KEEP_PROMOTED:
            keep[v["name"]] = (v, f"promoted, newest {KEEP_PROMOTED} besides latest")
        else:
            drop[v["name"]] = (v, f"promoted, older than the newest {KEEP_PROMOTED} besides latest")

    # Resolve children first: any error stops the script before it deletes
    token = registry_token()
    protected = set(keep)
    for digest in keep:
        protected.update(children(digest, token))
    dropped_children = {}
    for digest in drop:
        for child in children(digest, token):
            dropped_children[child] = digest

    by_digest = {v["name"]: v for v in versions}
    plan = []  # (version, reason), indexes first
    for digest, (v, reason) in drop.items():
        if digest not in protected:
            plan.append((v, reason))
    for v in versions:
        digest = v["name"]
        if v["metadata"]["container"]["tags"] or digest in protected or digest in drop:
            continue
        if digest in dropped_children:
            plan.append((v, f"child of dropped {dropped_children[digest][7:19]}"))
            continue
        created = datetime.fromisoformat(v["created_at"].replace("Z", "+00:00"))
        if now - created > timedelta(days=1):
            plan.append((v, "untagged, no kept image refers to it"))

    lines = [
        f"## r-runner cleanup{' (dry run)' if DRY_RUN else ''}",
        "",
        f"{len(versions)} versions, keeping {len(versions) - len(plan)}, deleting {len(plan)}.",
        "",
        "| | Version | Digest | Tags | Reason |",
        "|---|---|---|---|---|",
    ]
    for digest, (v, reason) in keep.items():
        lines.append(f"| keep | {v['id']} | `{digest[7:19]}` | {','.join(v['metadata']['container']['tags'])} | {reason} |")
    for v, reason in plan:
        lines.append(f"| delete | {v['id']} | `{v['name'][7:19]}` | {','.join(v['metadata']['container']['tags'])} | {reason} |")
    report = "\n".join(lines)
    print(report)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as f:
            f.write(report + "\n")

    if DRY_RUN:
        return
    failed = 0
    for v, _ in plan:
        try:
            github(f"/orgs/{ORG}/packages/container/{PACKAGE}/versions/{v['id']}", method="DELETE")
            print(f"deleted {v['id']} {v['name'][7:19]}")
        except urllib.error.HTTPError as e:
            print(f"::warning title=r-runner cleanup::Couldn't delete version {v['id']}: HTTP {e.code}")
            failed += 1
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
