#!/usr/bin/env python3
"""Asserts Gate G1 rejects EVERY capsule in tests/hostile_capsules (the immune-system regression corpus).

Runs G1 once over the whole corpus and requires each hostile capsule id to appear in the error output,
so an argparse typo or a crashed checker can never produce a vacuous pass.
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HOSTILE_ROOT = ROOT / "tests" / "hostile_capsules"
EXPECTED = 20


def main() -> int:
    dirs = sorted(p for p in (HOSTILE_ROOT / "hostile").iterdir() if p.is_dir())
    if len(dirs) < EXPECTED:
        print(f"FAILED: expected at least {EXPECTED} hostile capsules, found {len(dirs)}.")
        return 1
    res = subprocess.run(
        [sys.executable, "tools/check_capsules.py", "--strict", "--dir", str(HOSTILE_ROOT)],
        cwd=ROOT, capture_output=True, text=True,
    )
    out = res.stdout + res.stderr
    if res.returncode == 0 or "FAILED:" not in out:
        print("FAILED: checker did not reject the hostile corpus.")
        print(out[-2000:])
        return 1
    missed = [d.name for d in dirs if f"[hostile/{d.name}]" not in out]
    if missed:
        print(f"FAILED: G1 did not flag {len(missed)} hostile capsule(s): {', '.join(missed)}")
        return 1
    print(f"HOSTILE CORPUS OK: G1 rejected {len(dirs)}/{len(dirs)} hostile capsules.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
