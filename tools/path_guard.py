#!/usr/bin/env python3
"""Path guard: a content session may only ADD new capsule folders (and short proposal notes).

Allowed (added files only):
  content/capsules/<namespace>/<slug>/capsule.json   (max 5 new capsules per change, <= 32 KB each)
  proposals/<name>.md                                (<= 16 KB)
Anything else (edits, deletions, renames, engine/, vocab/, tools/, tests/, workflows) is rejected.

Usage: python3 tools/path_guard.py --base origin/main [--head HEAD]
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CAPSULE_RE = re.compile(r"^content/capsules/([a-z0-9_]{1,40})/([a-z0-9_]{1,80})/capsule\.json$")
GUILD_CAPSULE_RE = re.compile(r"^(?:guild/)?content/capsules/willow-guild-[a-z0-9-]{1,80}\.json$")
PROPOSAL_RE = re.compile(r"^(?:guild/)?proposals/[a-z0-9_-]{1,80}\.md$")
MAX_CAPSULES = 5
MAX_CAPSULE_BYTES = 32 * 1024
MAX_PROPOSAL_BYTES = 16 * 1024


def git(*args: str, cwd: Path = ROOT) -> str:
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, check=True).stdout


def main() -> int:
    ap = argparse.ArgumentParser(description="Reject content changes that stray outside new capsule folders.")
    ap.add_argument("--root", type=Path, default=ROOT, help="Project or Guild root directory")
    ap.add_argument("--base", default="origin/main")
    ap.add_argument("--head", default="HEAD")
    args = ap.parse_args()
    root_dir = args.root.resolve()
    is_guild = ((root_dir / "vocab" / "core_verbs.json").is_file() and root_dir.name == "guild") or (root_dir / "guild_schema.json").is_file()

    try:
        out = git("diff", "--name-status", "--no-renames", f"{args.base}...{args.head}", cwd=root_dir)
    except subprocess.CalledProcessError as exc:
        print(f"PATH GUARD ERROR: cannot diff {args.base}...{args.head}: {exc.stderr.strip()}")
        return 2

    errors: list[str] = []
    capsules = 0
    for raw in out.splitlines():
        status, _, path = raw.partition("\t")
        if status != "A":
            errors.append(f"{path}: status '{status}' not allowed (content sessions may only ADD files).")
            continue
        try:
            size = int(git("cat-file", "-s", f"{args.head}:{path}", cwd=root_dir).strip())
        except (subprocess.CalledProcessError, ValueError):
            size = 0
        if CAPSULE_RE.match(path) or (is_guild and GUILD_CAPSULE_RE.match(path)):
            capsules += 1
            if size > MAX_CAPSULE_BYTES:
                errors.append(f"{path}: {size} bytes exceeds {MAX_CAPSULE_BYTES}.")
        elif PROPOSAL_RE.match(path):
            if size > MAX_PROPOSAL_BYTES:
                errors.append(f"{path}: {size} bytes exceeds {MAX_PROPOSAL_BYTES}.")
        else:
            errors.append(f"{path}: outside the allowed paths (content/capsules/<ns>/<slug>/capsule.json, proposals/<name>.md).")
    if capsules > MAX_CAPSULES:
        errors.append(f"{capsules} new capsules exceeds the maximum of {MAX_CAPSULES} per change.")
    if not out.strip():
        errors.append("No changes found versus base: nothing to submit.")

    if errors:
        for e in errors:
            print(f"PATH GUARD: {e}")
        print("PATH GUARD FAILED")
        return 1
    print(f"PATH GUARD OK ({capsules} new capsule(s)).")
    return 0


if __name__ == "__main__":
    sys.exit(main())

