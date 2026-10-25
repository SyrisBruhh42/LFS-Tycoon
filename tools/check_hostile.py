#!/usr/bin/env python3
"""Asserts Gate G1 rejects EVERY capsule in tests/hostile_capsules (20 runtime/core)
and tests/hostile_static (4 static/progression laws L11v2, L13, L14, L15).

Runs G1 once over each corpus and requires each hostile capsule id to appear in the error output,
so an argparse typo or a crashed checker can never produce a vacuous pass.
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HOSTILE_ROOT = ROOT / "tests" / "hostile_capsules"
HOSTILE_STATIC_ROOT = ROOT / "tests" / "hostile_static"
EXPECTED_CORE = 20
EXPECTED_STATIC = 4


def _verify_corpus(corpus_root: Path, expected_count: int, label: str) -> tuple[bool, int]:
    hostile_dir = corpus_root / "hostile"
    if not hostile_dir.exists():
        print(f"FAILED: missing {label} hostile directory: {hostile_dir}")
        return False, 0
    dirs = sorted(p for p in hostile_dir.iterdir() if p.is_dir())
    if len(dirs) < expected_count:
        print(f"FAILED: expected at least {expected_count} {label} hostile capsules, found {len(dirs)}.")
        return False, len(dirs)
    res = subprocess.run(
        [sys.executable, "tools/check_capsules.py", "--strict", "--dir", str(corpus_root)],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    out = res.stdout + res.stderr
    if res.returncode == 0 or "FAILED:" not in out:
        print(f"FAILED: checker did not reject the {label} hostile corpus.")
        print(out[-2000:])
        return False, len(dirs)
    missed = [d.name for d in dirs if f"[hostile/{d.name}]" not in out]
    if missed:
        print(f"FAILED: G1 did not flag {len(missed)} {label} hostile capsule(s): {', '.join(missed)}")
        print(out[-2000:])
        return False, len(dirs)
    return True, len(dirs)


def main() -> int:
    ok_core, n_core = _verify_corpus(HOSTILE_ROOT, EXPECTED_CORE, "runtime/core")
    if not ok_core:
        return 1
    ok_static, n_static = _verify_corpus(HOSTILE_STATIC_ROOT, EXPECTED_STATIC, "static/progression")
    if not ok_static:
        return 1
    total = n_core + n_static
    print(
        f"HOSTILE CORPUS OK: G1 rejected {total}/{total} hostile capsules "
        f"({n_core} runtime/core + {n_static} static/progression)."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

