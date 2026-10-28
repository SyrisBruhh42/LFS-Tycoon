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
        "## 5. Under-Referenced Ores & Specialist NPCs (High-Synergy Targets)",
    ])
    try:
        if str(ROOT / "tools") not in sys.path:
            sys.path.insert(0, str(ROOT / "tools"))
        import content_graph
        g = content_graph.build()
        manifest_lines.append("- **Orphan / Low-Use Blocks (prioritize in `offered_by.price`, `biome_weights`, and reactions):** " +
                              ", ".join(f"`{b}` (z>={int(g.z_unlock(b))}, uses={g.consumer_count(b)})" for b in sorted(g.blocks, key=lambda x: g.consumer_count(x))[:10]))
        manifest_lines.append("- **Under-Stocked Specialist NPCs (prioritize in `offered_by.vendor`):** " +
                              ", ".join(f"`{n}` (offers={g.vendor_offers.get(n, 0)})" for n in sorted(g.npcs, key=lambda x: g.vendor_offers.get(x, 0))[:10]))
        s_nodes = sorted(g.skill_bracket_nodes(), key=lambda x: (not x["explicit_skill"], x["dependent_count"], x["unlock_depth"]))[:12]
        manifest_lines.append("- **Live Modular Skill Brackets & Station Prerequisites (reference in `offered_by.price` as non-consumed requirements or advance to next `bracket_<1..5>`):** " +
                              ", ".join(f"`{s['id']}` (B{s['bracket']}, {s['school']}, deps={s['dependent_count']})" for s in s_nodes))
    except Exception:
        pass
    manifest_lines.append("")
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
    try:
        if str(ROOT / "tools") not in sys.path:
            sys.path.insert(0, str(ROOT / "tools"))
        import build_manifest
        build_manifest.build_manifest(write=True)
    except Exception:
        pass
    try:
        build_aegis_asset_bridge()
    except Exception:
        pass
    print(f"OK: Generated AI_CONTEXT_MANIFEST.md ({sum(len(v) for v in capsules_by_ns.values())} capsules), GAP_MAP.md, content/capsule_manifest.json, and content/aegis_asset_bridge.json.")
    return 0


def build_aegis_asset_bridge() -> dict:
    """Emits content/aegis_asset_bridge.json for Aegis Hub / LFS_TrashArcade (0a728b45),
    Willow Companion & Wardrobe Studio (ca85e78a / 80ed872f), CP-11 (1f481664), and Enclave of the 16 (733881f5)."""
    if str(ROOT / "tools") not in sys.path:
        sys.path.insert(0, str(ROOT / "tools"))
    import content_graph
    g = content_graph.build()
    entities = []
    for bid in sorted(g.blocks)[:8]:
        raw = g.caps.get(bid, {})
        meta = raw.get("meta", {})
        entities.append({
            "id": bid,
            "name": str(meta.get("name", bid)),
            "kind": "stratum_block",
            "z_unlock": int(g.z_unlock(bid)),
            "summary": str(meta.get("description", ""))[:140],
        })
    for nid in sorted(g.npcs)[:6]:
        raw = g.caps.get(nid, {})
        meta = raw.get("meta", {})
        entities.append({
            "id": nid,
            "name": str(meta.get("name", nid)),
            "kind": "specialist_npc",
            "unlock_depth": int(g._npc_depth(nid)),
            "offers": int(g.vendor_offers.get(nid, 0)),
            "summary": str(meta.get("description", ""))[:140],
        })
    upgrades = []
    for s in sorted(g.skill_bracket_nodes(), key=lambda x: (not x["explicit_skill"], -x["dependent_count"], x["id"]))[:12]:
        raw = g.caps.get(s["id"], {})
        meta = raw.get("meta", {})
        upgrades.append({
            "id": s["id"],
            "name": str(meta.get("name", s["id"])),
            "bracket": f"bracket_{s['bracket']}",
            "school": s["school"],
            "dependents": s["dependent_count"],
            "summary": str(meta.get("description", ""))[:140],
        })
    bridge = {
        "schema": "aegis-asset-bridge-v1",
        "projectId": "PF-07",
        "capsuleId": "lfs-tycoon",
        "title": "LFS Tycoon: StrataPaper Quarry & Forge",
        "portalArchetype": "Deep-Strata Quarry, 11-Discipline Tinker Forge & Autonomous World Engine",
        "portalBadge": "STRATA-FORGE",
        "inspirationTitles": ["Tinkers' Construct", "Terraria", "Skyrim", "Munchkin"],
        "sessionLength": "3-15 min active / 24h offline catch-up",
        "goalSummary": "Excavate the 14x31 layered quarry, unlock 5 Modular Skill Brackets across 11 crafting disciplines, socket Tinker parts, fuse Terraria gear, and outfit Willow's Wardrobe.",
        "loreHook": "Beneath the Singing Abyss and the Enclave's First Forge lies the Great Ledger Beneath—where acoustic monks, clockwork syndicates, and siege geomancers transmute bedrock into living relics.",
        "artPalette": "Evergreen Dark & Subterranean Brass",
        "paletteSwatches": ["#141F1B", "#1B2924", "#6EE7B7", "#D97706", "#38BDF8", "#F43F5E"],
        "capsuleCount": len(g.caps),
        "frontierDepthZ": g.frontier_depth(),
        "openBrackets": g.open_brackets(),
        "entities": entities,
        "upgrades": upgrades,
        "howToPlaySteps": [
            "Hold-press or drag across the 14x31 quarry grid to excavate strata, bail flooded aquifers, and detonate 8-perimeter Obsidian Hazards.",
            "Open [⚒ Forge] to craft across 11 disciplines—unlocking non-consumed Modular Skill Brackets (`bracket_1`..`bracket_5`) and fusing socketed tools.",
            "Open [Homestead] to claim Paired Chest loot, switch CP-11 LDS theme packs, and sync forged regalia to Willow's Desktop Pet Wardrobe."
        ],
        "optionsSchema": [
            {"group": "Audio & Mix", "keys": ["comfort.audio_muted"], "summary": "Master quarry acoustic resonance and autoplay mute."},
            {"group": "Visual Comfort", "keys": ["theme.pack", "comfort.reduced_motion"], "summary": "CP-11 LDS 4-pack themes (evergreen-dark, evergreen-light, high-contrast, calm) & reduced motion."},
            {"group": "Control Mode", "keys": ["comfort.haptics_enabled"], "summary": "48dp touch-safe inline steppers, one-handed drawer dock, and haptics toggle."},
            {"group": "Save & Reset", "keys": ["safe_mode.supported"], "summary": "Atomic save/load with dormant-stub forward/backward compatibility and ZT-10 safe mode."}
        ],
        "willowCompanion": {
            "companionName": "Willow",
            "role": "Chief Quarry Assayer & LFS Suite Face",
            "authority": "lfs-local-abac-v1",
            "capability": "lfs.game.item.use",
            "offlineUsable": True,
            "wardrobeSlots": ["back_accessory", "boots", "chassis_dress", "visor", "headpiece", "held_prop"],
            "wardrobeThemes": ["astral-clockwork", "tactical-valkyrie", "cyber-couture", "cozy-tech", "royal-valkyrie", "botanical-fae", "street-tech"],
            "entitlementExportPath": "user://willow_wardrobe_entitlements.json"
        },
        "enclaveConcordance": {
            "repo": "enclave-digital-twin",
            "squadMappings": [
                {"squad": "The Forge", "members": ["Silas (ISTJ)", "Leo (ENTJ)", "Hector (ESTP)", "Jane (INTP)"], "theme": "theme_enclave_first_forge", "grandProjects": ["The First Forge", "The Stormbreaker"]},
                {"squad": "The Wilds", "members": ["Kaio (ENFP)", "Zara (ISFP)", "Willow (ISTP)", "Terra (ISFJ)"], "theme": "theme_enclave_living_atlas", "grandProjects": ["The Genesis Garden", "The Sanctuary"]},
                {"squad": "The Mind", "members": ["Orion (INFP)", "Isla (INTJ)", "Kenna (ENFJ)", "Elias (INFJ)"], "theme": "theme_lithic_choir", "grandProjects": ["The Simulacrum", "The Lyceum of the Mind"]},
                {"squad": "The Hub", "members": ["Ryn (ESTJ)", "Vex (ENTP)", "Dorian (ESFP)", "Elara (ESFJ)"], "theme": "theme_clockwork_syndicate", "grandProjects": ["The Living Atlas & Mycelial Concordance", "The Hearth"]}
            ]
        }
    }
    out_path = ROOT / "content" / "aegis_asset_bridge.json"
    out_path.write_text(json.dumps(bridge, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return bridge


if __name__ == "__main__":
    sys.exit(main())
