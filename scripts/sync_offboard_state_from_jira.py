#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = []
# ///
"""
Sync offboarding pipeline_state.json from Jira labels and comment URLs.

Usage:
  uv run --script sync_offboard_state_from_jira.py \
    --jira-details <component_onboarding_details.json> \
    --pipeline-state <pipeline_state.json>
"""
import argparse
import json
import re
import sys
from pathlib import Path

LABEL_MAP: dict[str, tuple[str, str]] = {
    "offboard-operator-pr-raised":        ("remove_operator",        "pr_raised"),
    "offboard-operator-pr-merged":        ("remove_operator",        "done"),
    "offboard-bundle-pr-raised":          ("remove_bundle",          "pr_raised"),
    "offboard-bundle-pr-merged":          ("remove_bundle",          "done"),
    "offboard-auto-merge-pr-raised":      ("remove_auto_merge",      "pr_raised"),
    "offboard-auto-merge-pr-merged":      ("remove_auto_merge",      "done"),
    "offboard-renovate-pr-raised":        ("remove_renovate",        "pr_raised"),
    "offboard-renovate-pr-merged":        ("remove_renovate",        "done"),
    "offboard-okc-pr-raised":             ("remove_okc",             "pr_raised"),
    "offboard-okc-pr-merged":            ("remove_okc",             "done"),
    "offboard-pull-pipelines-pr-raised":  ("remove_pull_pipelines",  "pr_raised"),
    "offboard-pull-pipelines-pr-merged":  ("remove_pull_pipelines",  "done"),
    "offboard-krd-mr-raised":             ("remove_krd",             "mr_raised"),
    "offboard-krd-mr-merged":             ("remove_krd",             "done"),
    "offboard-product-listing-mr-raised": ("remove_product_listing", "mr_raised"),
    "offboard-product-listing-done":      ("remove_product_listing", "done"),
    "offboard-delivery-repo-mr-raised":   ("remove_delivery_repo",   "mr_raised"),
    "offboard-delivery-repo-done":        ("remove_delivery_repo",   "done"),
    "offboard-quay-mr-raised":            ("remove_quay",            "mr_raised"),
    "offboard-quay-done":                 ("remove_quay",            "done"),
}

STEP_URL_PATTERNS: list[tuple[str, str, re.Pattern]] = [
    ("remove_quay",        "mr_url",  re.compile(r"app-interface/-/merge_requests/", re.I)),
    ("remove_krd",         "mr_url",  re.compile(r"konflux-release-data/-/merge_requests/", re.I)),
    ("remove_operator",    "pr_url",  re.compile(r"(?:opendatahub-operator|rhods-operator)/pull/", re.I)),
    ("remove_bundle",      "pr_url",  re.compile(r"(?:ODH|RHOAI)-Build-Config/pull/", re.I)),
    ("remove_auto_merge",  "pr_url",  re.compile(r"rhods-devops-infra/pull/", re.I)),
]

SHARED_URL_PATTERNS: list[tuple[str, str, re.Pattern, re.Pattern]] = [
    ("remove_delivery_repo",   "mr_url",  re.compile(r"pyxis-repo-configs/-/merge_requests/", re.I),
                                      re.compile(r"\[step:remove_delivery_repo\]|delivery.repo", re.I)),
    ("remove_product_listing", "mr_url",  re.compile(r"pyxis-repo-configs/-/merge_requests/", re.I),
                                      re.compile(r"\[step:remove_product_listing\]|product.listing", re.I)),
    ("remove_okc",  "pr_url",  re.compile(r"konflux-central/pull/", re.I),
                                      re.compile(r"\[step:remove_okc\]|push.pipeline", re.I)),
    ("remove_pull_pipelines",  "pr_url",  re.compile(r"konflux-central/pull/", re.I),
                                      re.compile(r"\[step:remove_pull_pipelines\]|pull.pipeline", re.I)),
    ("remove_renovate",        "pr_url",  re.compile(r"konflux-central/pull/", re.I),
                                      re.compile(r"\[step:remove_renovate\]|renovate", re.I)),
]

_URL_RE = re.compile(r"https://(?:github\.com/[^\s/]+/[^\s/]+/pull/\d+|gitlab[^\s|)\]]+/-/merge_requests/\d+)")


def _flatten_adf(node) -> str:
    parts: list[str] = []
    if isinstance(node, dict):
        if node.get("type") == "text":
            parts.append(node.get("text", ""))
        for mark in node.get("marks", []):
            if mark.get("type") == "link":
                parts.append(mark.get("attrs", {}).get("href", ""))
        for child in node.get("content", []):
            parts.append(_flatten_adf(child))
    elif isinstance(node, list):
        for item in node:
            parts.append(_flatten_adf(item))
    return " ".join(parts)


def extract_urls_from_comment(body) -> list[str]:
    if isinstance(body, dict):
        body = _flatten_adf(body)
    return _URL_RE.findall(body or "")


def sync_labels(state: dict, labels: list[str]) -> list[str]:
    changes = []
    for label in labels:
        mapping = LABEL_MAP.get(label)
        if not mapping:
            continue
        step_key, new_status = mapping
        step = state.get("steps", {}).get(step_key)
        if step is None:
            continue
        current = step.get("status", "pending")
        if new_status == "done":
            if current not in ("done",):
                step["status"] = "done"
                changes.append(f"{step_key}: {current} → done (label: {label})")
        else:
            if current in ("pending", "skipped"):
                step["status"] = new_status
                changes.append(f"{step_key}: {current} → {new_status} (label: {label})")
    return changes


def sync_urls_from_comments(state: dict, comments: list[dict], labels: list[str]) -> list[str]:
    changes = []
    all_comment_bodies: list[str] = []
    for c in reversed(comments):
        body = c.get("body") or ""
        if isinstance(body, dict):
            body = _flatten_adf(body)
        all_comment_bodies.append(body)

    all_urls: list[str] = []
    for body in all_comment_bodies:
        all_urls.extend(extract_urls_from_comment(body))
    seen: set[str] = set()
    unique_urls: list[str] = []
    for url in all_urls:
        if url not in seen:
            seen.add(url)
            unique_urls.append(url)
    all_urls = unique_urls

    claimed_urls: set[str] = set()

    label_to_steps: dict[str, set] = {}
    for label, (step_key, _status) in LABEL_MAP.items():
        label_to_steps.setdefault(step_key, set()).add(label)
    label_set = set(labels)

    def _step_has_label(step_key: str) -> bool:
        return bool(label_to_steps.get(step_key, set()) & label_set)

    for step_key, url_field, url_re in STEP_URL_PATTERNS:
        step = state.get("steps", {}).get(step_key)
        if step is None or step.get(url_field, ""):
            continue
        for url in all_urls:
            if url in claimed_urls:
                continue
            if url_re.search(url):
                step[url_field] = url
                claimed_urls.add(url)
                changes.append(f"{step_key}.{url_field} = {url} (from comment)")
                break

    for step_key, url_field, url_re, kw_re in SHARED_URL_PATTERNS:
        step = state.get("steps", {}).get(step_key)
        if step is None or step.get(url_field, ""):
            continue
        if not _step_has_label(step_key):
            continue
        for body in all_comment_bodies:
            if not kw_re.search(body):
                continue
            body_urls = extract_urls_from_comment(body)
            for url in body_urls:
                if url in claimed_urls:
                    continue
                if url_re.search(url):
                    step[url_field] = url
                    claimed_urls.add(url)
                    changes.append(f"{step_key}.{url_field} = {url} (from comment)")
                    break
            if step.get(url_field, ""):
                break

    return changes


def write_state(state: dict, path: Path) -> None:
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2) + "\n")
    tmp.rename(path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--jira-details", required=True)
    parser.add_argument("--pipeline-state", required=True)
    args = parser.parse_args()

    jira_path = Path(args.jira_details)
    state_path = Path(args.pipeline_state)

    if not jira_path.exists():
        print(f"ERROR: Jira details file not found: {jira_path}", file=sys.stderr)
        sys.exit(1)
    if not state_path.exists():
        print(f"ERROR: Pipeline state file not found: {state_path}", file=sys.stderr)
        sys.exit(1)

    jira = json.loads(jira_path.read_text())
    state = json.loads(state_path.read_text())

    labels: list[str] = jira.get("fields", {}).get("labels", [])
    comments_raw = jira.get("fields", {}).get("comment", {}).get("comments", [])

    all_changes: list[str] = []
    all_changes.extend(sync_labels(state, labels))
    all_changes.extend(sync_urls_from_comments(state, comments_raw, labels))

    if all_changes:
        write_state(state, state_path)
        for change in all_changes:
            print(f"[sync] {change}", file=sys.stderr)
        print(f"[sync] {len(all_changes)} field(s) updated in pipeline_state.json", file=sys.stderr)
    else:
        print("[sync] No changes — pipeline_state.json already matches Jira labels.", file=sys.stderr)


if __name__ == "__main__":
    main()
