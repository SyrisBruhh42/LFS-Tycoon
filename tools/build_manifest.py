#!/usr/bin/env python3
"""
Builds and verifies the deterministic SHA-256 content manifest (`content/capsule_manifest.json`)
for all capsules under `content/capsules/*/*/capsule.json`.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent.parent
CAPSULES_DIR = ROOT / "content" / "capsules"
MANIFEST_PATH = ROOT / "content" / "capsule_manifest.json"


def build_manifest(write: bool = True) -> dict:
    capsules: dict[str, dict[str, object]] = {}
    for p in sorted(CAPSULES_DIR.glob("*/*/capsule.json")):
        rel = p.relative_to(CAPSULES_DIR)
        cid = f"{rel.parts[0]}/{rel.parts[1]}"
        raw = p.read_bytes()
        sha = hashlib.sha256(raw).hexdigest()
        capsules[cid] = {
            "sha256": sha,
            "bytes": len(raw),
        }
    payload = {
        "schema": 1,
        "capsule_count": len(capsules),
        "capsules": dict(sorted(capsules.items())),
    }
    if write:
        MANIFEST_PATH.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    return payload


def verify_manifest(allow_new: bool = False) -> tuple[bool, list[str]]:
    if not MANIFEST_PATH.exists():
        return False, [f"Manifest file not found: {MANIFEST_PATH}"]
    try:
        recorded_payload = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    except Exception as exc:
        return False, [f"Manifest JSON parse error: {exc}"]

    recorded = recorded_payload.get("capsules", {})
    if not isinstance(recorded, dict):
        return False, ["Manifest 'capsules' field must be an object"]

    live = build_manifest(write=False)["capsules"]
    errors: list[str] = []

    for cid, exp in sorted(recorded.items()):
        if cid not in live:
            errors.append(f"{cid}: missing on disk")
            continue
        act = live[cid]
        if act["sha256"] != exp.get("sha256") or act["bytes"] != exp.get("bytes"):
            errors.append(
                f"{cid}: hash/size mismatch (expected sha256={exp.get('sha256')}, got {act['sha256']})"
            )

    if not allow_new:
        for cid in sorted(live.keys()):
            if cid not in recorded:
                errors.append(f"{cid}: unrecorded capsule on disk (run build_manifest.py or pass --allow-new)")

    return len(errors) == 0, errors


def main() -> int:
    parser = argparse.ArgumentParser(description="Build or verify content/capsule_manifest.json")
    parser.add_argument("--verify", action="store_true", help="Verify disk capsules against capsule_manifest.json")
    parser.add_argument("--allow-new", action="store_true", help="Allow newly added capsules not yet in manifest during --verify")
    args = parser.parse_args()

    if args.verify:
        ok, errors = verify_manifest(allow_new=args.allow_new)
        if not ok:
            for err in errors:
                print(f"[FAIL] {err}", file=sys.stderr)
            return 1
        print("OK: capsule_manifest.json verified against disk.")
        return 0

    payload = build_manifest(write=True)
    print(f"OK: Wrote {MANIFEST_PATH.relative_to(ROOT)} ({payload['capsule_count']} capsules).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
