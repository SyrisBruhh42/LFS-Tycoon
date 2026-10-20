#!/usr/bin/env python3
"""One-shot pre-submit check for content sessions. Mirrors the CI gate (path guard + G1 strict + semantic checks).

Usage: python3 tools/preflight.py
Commit your new capsule first (or stage it), then run this. Exit 0 means safe to submit.
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def run(*cmd: str) -> int:
    return subprocess.run(cmd, cwd=ROOT).returncode


def main() -> int:
    subprocess.run(["git", "fetch", "origin", "main"], cwd=ROOT, capture_output=True)
    base = "origin/main"
    have_base = subprocess.run(["git", "rev-parse", "--verify", base], cwd=ROOT, capture_output=True).returncode == 0

    # Make staged/untracked new capsules visible to the diff-based path guard by checking them directly too.
    status = subprocess.run(["git", "status", "--porcelain"], cwd=ROOT, capture_output=True, text=True).stdout
    dirty = [ln for ln in status.splitlines() if ln.strip()]
    if dirty and have_base:
        print("NOTE: uncommitted changes found. Commit them before submitting; path guard compares commits.")
        for ln in dirty:
            print("   " + ln)

    new_files_set: set[str] = set()
    if have_base:
        committed_new = subprocess.run(
            ["git", "diff", "--name-only", "--diff-filter=A", f"{base}...HEAD"],
            cwd=ROOT, capture_output=True, text=True,
        ).stdout.splitlines()
        new_files_set.update(committed_new)
    untracked = subprocess.run(
        ["git", "ls-files", "-o", "--exclude-standard"],
        cwd=ROOT, capture_output=True, text=True,
    ).stdout.splitlines()
    new_files_set.update(untracked)
    staged_new = subprocess.run(
        ["git", "diff", "--cached", "--name-only", "--diff-filter=A"],
        cwd=ROOT, capture_output=True, text=True,
    ).stdout.splitlines()
    new_files_set.update(staged_new)

    new_capsule_args: list[str] = []
    for rel in sorted(new_files_set):
        if rel.startswith("content/capsules/") and rel.endswith("capsule.json"):
            new_capsule_args.extend(["--new-capsule", rel])

    rc = 0
    if have_base:
        rc |= run(sys.executable, "tools/path_guard.py", "--base", base)
    else:
        print("WARN: origin/main not reachable; skipping path guard (CI will enforce it).")
    rc |= run(sys.executable, "tools/check_capsules.py", "--strict", *new_capsule_args)

    print("PREFLIGHT OK: submit now." if rc == 0 else "PREFLIGHT FAILED: fix the errors above, re-commit, and re-run.")
    return 0 if rc == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
