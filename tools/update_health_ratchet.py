#!/usr/bin/env python3
"""Monotone Corpus Health Ratchet Updater for LFS-Tycoon (Codename: StrataPaper).

Computes live progression & economy diversity metrics across content/capsules and
monotonically tightens design/health_baseline.json:
  - min() for concentration shares (max_vendor_offer_share, top3_currency_share)
  - max() for depth & multi-hop ratios (non_block_ingredient_offer_ratio, frontier_depth_z)
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
from typing import Any, Dict

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CAPSULES_DIR = ROOT / "content" / "capsules"
DEFAULT_BASELINE_PATH = ROOT / "design" / "health_baseline.json"


def compute_live_health_metrics(capsules_dir: Path) -> Dict[str, Any]:
    capsules: Dict[str, Dict[str, Any]] = {}
    for p in sorted(capsules_dir.glob("*/*/capsule.json")):
        rel = p.relative_to(capsules_dir)
        cid = f"{rel.parts[0]}/{rel.parts[1]}"
        capsules[cid] = json.loads(p.read_text(encoding="utf-8"))

    vendor_counts: Dict[str, int] = {}
    curr_counts: Dict[str, int] = {}
    total_offers = 0
    non_block_offers = 0

    for cid, data in capsules.items():
        for offer in data.get("offered_by", []) or []:
            if not isinstance(offer, dict):
                continue
            total_offers += 1
            vendor = str(offer.get("vendor", ""))
            if vendor:
                vendor_counts[vendor] = vendor_counts.get(vendor, 0) + 1
            price = offer.get("price", {}) or {}
            has_non_block = False
            if isinstance(price, dict):
                for curr_id in price:
                    curr_counts[curr_id] = curr_counts.get(curr_id, 0) + 1
                    if not str(curr_id).startswith("blocks/"):
                        has_non_block = True
            if has_non_block:
                non_block_offers += 1

    max_vendor_share = 0.0
    top_vendor = ""
    if total_offers > 0 and vendor_counts:
        top_vendor, max_v_count = max(vendor_counts.items(), key=lambda kv: kv[1])
        max_vendor_share = max_v_count / float(total_offers)

    total_curr_mentions = sum(curr_counts.values())
    top3_curr_share = 0.0
    if total_curr_mentions > 0 and curr_counts:
        top3 = sorted(curr_counts.items(), key=lambda kv: kv[1], reverse=True)[:3]
        top3_curr_share = sum(cnt for _, cnt in top3) / float(total_curr_mentions)

    non_block_ratio = (non_block_offers / float(total_offers)) if total_offers > 0 else 0.0

    frontier_z = max(
        (
            float(c.get("stats", {}).get("z_unlock", 0.0))
            for cid, c in capsules.items()
            if cid.startswith("blocks/") and isinstance(c.get("stats"), dict)
        ),
        default=150.0,
    )

    return {
        "capsule_count": len(capsules),
        "total_offers": total_offers,
        "top_vendor": top_vendor,
        "metrics": {
            "max_vendor_offer_share": round(max_vendor_share, 6),
            "top3_currency_share": round(top3_curr_share, 6),
            "non_block_ingredient_offer_ratio": round(non_block_ratio, 6),
            "frontier_depth_z": round(frontier_z, 1),
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Compute and monotonically ratchet corpus health metrics.")
    parser.add_argument("--dir", type=Path, default=DEFAULT_CAPSULES_DIR, help="Capsules root directory")
    parser.add_argument("--baseline", type=Path, default=DEFAULT_BASELINE_PATH, help="Path to design/health_baseline.json")
    parser.add_argument("--write", action="store_true", help="Write tightened monotone baseline back to disk")
    args = parser.parse_args()

    live = compute_live_health_metrics(args.dir)
    live_m = live["metrics"]

    if args.baseline.exists():
        baseline_doc = json.loads(args.baseline.read_text(encoding="utf-8"))
    else:
        baseline_doc = {
            "schema": 1,
            "description": "Monotone corpus health ratchet baseline for LFS-Tycoon (StrataPaper).",
            "calibrated_at_capsules": live["capsule_count"],
            "single_capsule_tolerance": 0.005,
            "metrics": dict(live_m),
        }

    old_m = baseline_doc.get("metrics", {})
    tightened_m = {
        "max_vendor_offer_share": round(
            min(float(old_m.get("max_vendor_offer_share", live_m["max_vendor_offer_share"])), live_m["max_vendor_offer_share"]),
            6,
        ),
        "top3_currency_share": round(
            min(float(old_m.get("top3_currency_share", live_m["top3_currency_share"])), live_m["top3_currency_share"]),
            6,
        ),
        "non_block_ingredient_offer_ratio": round(
            max(
                float(old_m.get("non_block_ingredient_offer_ratio", live_m["non_block_ingredient_offer_ratio"])),
                live_m["non_block_ingredient_offer_ratio"],
            ),
            6,
        ),
        "frontier_depth_z": round(
            max(float(old_m.get("frontier_depth_z", live_m["frontier_depth_z"])), live_m["frontier_depth_z"]),
            1,
        ),
    }

    print(
        f"HEALTH RATCHET SUMMARY ({live['capsule_count']} capsules, {live['total_offers']} offers):\n"
        f"  max_vendor_offer_share:           live={live_m['max_vendor_offer_share']:.6f} "
        f"(baseline={float(old_m.get('max_vendor_offer_share', 0.0)):.6f} -> ratchet={tightened_m['max_vendor_offer_share']:.6f})\n"
        f"  top3_currency_share:              live={live_m['top3_currency_share']:.6f} "
        f"(baseline={float(old_m.get('top3_currency_share', 0.0)):.6f} -> ratchet={tightened_m['top3_currency_share']:.6f})\n"
        f"  non_block_ingredient_offer_ratio: live={live_m['non_block_ingredient_offer_ratio']:.6f} "
        f"(baseline={float(old_m.get('non_block_ingredient_offer_ratio', 0.0)):.6f} -> ratchet={tightened_m['non_block_ingredient_offer_ratio']:.6f})\n"
        f"  frontier_depth_z:                 live={live_m['frontier_depth_z']:.1f} "
        f"(baseline={float(old_m.get('frontier_depth_z', 0.0)):.1f} -> ratchet={tightened_m['frontier_depth_z']:.1f})"
    )

    if args.write:
        baseline_doc["calibrated_at_capsules"] = live["capsule_count"]
        baseline_doc["metrics"] = tightened_m
        args.baseline.write_text(json.dumps(baseline_doc, indent=2) + "\n", encoding="utf-8")
        print(f"Wrote updated health ratchet baseline to {args.baseline}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
