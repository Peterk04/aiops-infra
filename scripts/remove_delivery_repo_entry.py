#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = []
# ///
"""
Remove a delivery repository entry from products/rhoai/rhoai.yaml (idempotent).

Counterpart to append_delivery_repo_entry.py.  Uses text-based block
removal rather than ruamel.yaml because the file contains YAML anchors
(e.g. *team_contacts) that ruamel struggles with.

Usage:
  uv run --script remove_delivery_repo_entry.py \
    --yaml-file <path/to/products/rhoai/rhoai.yaml> \
    --repository-name <repo-name>

Prints "removed" or "not-found" to stdout.
Exits 0 on success (including not-found), 1 on error.
"""
import argparse
import sys
from pathlib import Path


def _find_block(lines: list[str], repository_name: str) -> tuple[int, int] | None:
    repo_line_idx: int | None = None
    for idx, line in enumerate(lines):
        stripped = line.strip()
        if stripped == f"repository: {repository_name}":
            repo_line_idx = idx
            break

    if repo_line_idx is None:
        return None

    start = repo_line_idx
    while start > 0:
        start -= 1
        if lines[start].lstrip().startswith("- image_type:"):
            break
    else:
        if not lines[start].lstrip().startswith("- image_type:"):
            return None

    end = repo_line_idx + 1
    while end < len(lines):
        if lines[end].lstrip().startswith("- image_type:"):
            break
        end += 1

    return (start, end)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--yaml-file", required=True)
    parser.add_argument("--repository-name", required=True)
    args = parser.parse_args()

    yaml_path = Path(args.yaml_file)
    if not yaml_path.exists():
        print(f"ERROR: {yaml_path} not found", file=sys.stderr)
        sys.exit(1)

    content = yaml_path.read_text()
    marker = f"repository: {args.repository_name}"

    if marker not in content:
        print("not-found")
        print(
            f"Entry for '{args.repository_name}' not present — no changes made.",
            file=sys.stderr,
        )
        return

    newline = "\r\n" if "\r\n" in content else "\n"
    lines = content.splitlines(keepends=True)

    block = _find_block(lines, args.repository_name)
    if block is None:
        print(
            f"ERROR: Found '{marker}' but could not determine block boundaries",
            file=sys.stderr,
        )
        sys.exit(1)

    start, end = block
    del lines[start:end]

    while lines and lines[-1].strip() == "":
        lines.pop()

    result = "".join(lines)
    if result and not result.endswith(newline):
        result += newline

    yaml_path.write_text(result)

    verification = yaml_path.read_text()
    if marker in verification:
        print(
            f"ERROR: Verification failed — '{marker}' still present after removal",
            file=sys.stderr,
        )
        sys.exit(1)

    print("removed")
    print(
        f"Entry for '{args.repository_name}' removed from {yaml_path}.",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
