#!/usr/bin/env python3
"""One-shot pre-submit check for content sessions. Mirrors the CI gate (path guard + G1 strict).

Usage: python3 tools/preflight.py
Commit your new capsule first (or stage it), then run this. Exit 0 means safe to submit.
"""
from __future__ import annotations

import json
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

    rc = 0
    if have_base:
        rc |= run(sys.executable, "tools/path_guard.py", "--base", base)
    else:
        print("WARN: origin/main not reachable; skipping path guard (CI will enforce it).")
    rc |= run(sys.executable, "tools/check_capsules.py", "--strict")

    new_files = subprocess.run(
        ["git", "diff", "--name-only", "--diff-filter=A", f"{base}...HEAD"] if have_base else ["git", "ls-files", "-o", "--exclude-standard"],
        cwd=ROOT, capture_output=True, text=True,
    ).stdout.splitlines()
    for rel in new_files:
        if rel.startswith("content/capsules/") and rel.endswith("capsule.json"):
            try:
                tags = set(json.loads((ROOT / rel).read_text(encoding="utf-8")).get("tags", []))
            except Exception:
                continue
            if not any(t.startswith("solves_") for t in tags) and not any(t.startswith("world_") for t in tags):
                print(f"WARN: {rel} has no `solves_<friction>` or `world_<kind>` tag; add the brief's required tags so coverage tracking works.")
            if not any(t.startswith("path_") for t in tags) and not any(t.startswith("world_") for t in tags):
                print(f"WARN: {rel} has no `path_<type>` tag.")

    print("PREFLIGHT OK: submit now." if rc == 0 else "PREFLIGHT FAILED: fix the errors above, re-commit, and re-run.")
    return 0 if rc == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
