#!/usr/bin/env python3
"""
Generates uncommitted AI_CONTEXT_MANIFEST.md and GAP_MAP.md from live capsules.
Used by Google Jules sessions to discover existing tags, blocks, NPCs, shared vars,
and under-explored (event x action x affordance) design niches without editing shared files.
"""
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent.parent
VOCAB_DIR = ROOT / "vocab"
CAPSULES_DIR = ROOT / "content" / "capsules"


def main() -> int:
    events = json.loads((VOCAB_DIR / "events.json").read_text(encoding="utf-8"))["events"]
    actions = list(json.loads((VOCAB_DIR / "actions.json").read_text(encoding="utf-8"))["actions"].keys())
    affordances = json.loads((VOCAB_DIR / "affordances.json").read_text(encoding="utf-8"))["affordances"]
    shared_vars = json.loads((VOCAB_DIR / "shared_vars.json").read_text(encoding="utf-8"))["shared_vars"]

    capsules_by_ns: dict[str, list[str]] = {}
    all_tags: set[str] = set()
    event_counts: dict[str, int] = {e: 0 for e in events}
    action_counts: dict[str, int] = {a: 0 for a in actions}
    pair_counts: dict[tuple[str, str], int] = {}

    for p in sorted(CAPSULES_DIR.glob("*/*/capsule.json")):
        rel = p.relative_to(CAPSULES_DIR)
        ns, slug = rel.parts[0], rel.parts[1]
        cid = f"{ns}/{slug}"
        capsules_by_ns.setdefault(ns, []).append(cid)
        try:
            data = json.loads(p.read_text(encoding="utf-8"))
        except Exception:
            continue
        for t in data.get("tags", []):
            all_tags.add(t)
        for rx in data.get("reactions", []):
            ev = rx.get("on", "")
            if ev in event_counts:
                event_counts[ev] += 1
            for act_obj in rx.get("do", []):
                act = act_obj.get("act", "")
                if act in action_counts:
                    action_counts[act] += 1
                if ev and act:
                    pair_counts[(ev, act)] = pair_counts.get((ev, act), 0) + 1

    # Write AI_CONTEXT_MANIFEST.md
    manifest_lines = [
        "# AI CONTEXT MANIFEST (Auto-Generated — Do Not Commit)",
        "",
        "## 1. Existing Capsules by Namespace",
    ]
    for ns, cids in sorted(capsules_by_ns.items()):
        manifest_lines.append(f"- **`{ns}`**: " + ", ".join(f"`{c}`" for c in cids))

    manifest_lines.extend([
        "",
        "## 2. Active Tag Vocabulary",
        ", ".join(f"`{t}`" for t in sorted(all_tags)),
        "",
        "## 3. Declared Shared Registers (`shared.<key>`)",
    ])
    for k, meta in sorted(shared_vars.items()):
        manifest_lines.append(f"- `shared.{k}` (default `{meta['default']}`, range `[{meta['min']}, {meta['max']}]`): {meta['description']}")

    manifest_lines.extend([
        "",
        "## 4. Canonical Affordances",
        ", ".join(f"`{a}`" for a in affordances),
        "",
    ])
    (ROOT / "AI_CONTEXT_MANIFEST.md").write_text("\n".join(manifest_lines), encoding="utf-8")

    # Write GAP_MAP.md (Under-used Event x Action niches for parallel Jules ideation)
    unused_events = [e for e, c in event_counts.items() if c == 0]
    unused_actions = [a for a, c in action_counts.items() if c == 0]
    suggested_niches: list[str] = []
    for ev in events:
        for act in actions:
            if pair_counts.get((ev, act), 0) == 0 and act not in ("destroy_self",):
                suggested_niches.append(f"`{ev}` -> `{act}`")

    gap_lines = [
        "# DESIGN NICHE GAP MAP (Auto-Generated — Do Not Commit)",
        "",
        "## 1. Unexplored Trigger Hooks (`WHEN`)",
        ", ".join(f"`{e}`" for e in unused_events) if unused_events else "All events have at least 1 capsule.",
        "",
        "## 2. Unexplored Action Verbs (`DO`)",
        ", ".join(f"`{a}`" for a in unused_actions) if unused_actions else "All actions have at least 1 capsule.",
        "",
        "## 3. Top 25 Open `(Event -> Action)` Niches for New Jules Sessions",
    ]
    for niche in suggested_niches[:25]:
        gap_lines.append(f"- {niche}")
    (ROOT / "GAP_MAP.md").write_text("\n".join(gap_lines) + "\n", encoding="utf-8")
    print(f"OK: Generated AI_CONTEXT_MANIFEST.md ({sum(len(v) for v in capsules_by_ns.values())} capsules) and GAP_MAP.md.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
