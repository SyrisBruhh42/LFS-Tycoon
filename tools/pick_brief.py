#!/usr/bin/env python3
"""Prints a unique, synergy-weighted design brief for ONE autonomous content session.

Integrates with tools/content_graph.py to enforce:
  1. 10+ Multi-Disciplinary Crafting Concepts (Tinkers' Construct parts, Terraria item fusions,
     Skyrim enchanting sigils, RPG alchemy potions, Geomancy spell grimoires, Smeltery alloys,
     Skill mastery trees, Achievement relics, Homestead workshop stations, Clockwork automatons)
     plus Rare Exclusive NPCs and Pocket Mine Biomes.
  2. The Munchkin Logic-Spectrum Connector (45% Canonical, 30% Plausible, 15% Whimsical, 10% Munchkin-Absurd)
     pairing specialist NPCs, stratum ores, and prerequisite items by motif/material affinity.
  3. Every-10th-Session Enterprise Steward & Synergy Connector Review (plus every-50th Global Census),
     auditing the past 9 merged capsules and forging Keystone Connector recipes for orphan blocks/NPCs.
  4. In-flight anchor ledger awareness so concurrent sessions spread across different NPCs and ores.

Usage: python3 tools/pick_brief.py [--seed N] [--json] [--force-steward]
"""
from __future__ import annotations

import argparse
import json
import os
import random
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT / "tools") not in sys.path:
    sys.path.insert(0, str(ROOT / "tools"))

import content_graph  # noqa: E402

DESIGN = ROOT / "design" / "frictions.json"
STATE_DIR = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local" / "state"))) / "lfs-tycoon-factory"
STATE_FILE = STATE_DIR / "state.json"

WORLD_MODE_PROB = 0.12
RARITIES = [("common", 45), ("uncommon", 32), ("rare", 17), ("epic", 6)]
BANDS = [
    ("early", 45.0, "tool_tier 0-1; unlock_depth <= 45; recipe uses 15-120 of assigned stratum ore(s)"),
    ("mid", 180.0, "tool_tier 2-3; unlock_depth <= 180; multi-ingredient recipe (assigned ore + secondary block/item); include an unlock_if gate"),
    ("late", 600.0, "tool_tier 4+; deep stratum recipe (150-1200 of assigned deep ores + catalyst/item); must be unlock_if gated"),
]
BAND_WEIGHTS = [50, 35, 15]


def load_inflight_anchors() -> set[str]:
    """Reads currently active sessions from state.json so parallel sessions don't pick the same NPC/ore."""
    claimed: set[str] = set()
    try:
        state = json.loads(STATE_FILE.read_text(encoding="utf-8"))
        for rec in state.get("sessions", {}).values():
            if not rec.get("outcome"):
                for a in rec.get("anchors", []) or []:
                    claimed.add(str(a))
    except Exception:
        pass
    return claimed


def weighted_choice(rng: random.Random, items: list[str], counts: dict[str, int]) -> str:
    weights = [1.0 / (1.0 + counts.get(i, 0)) ** 2 for i in items]
    return rng.choices(items, weights=weights, k=1)[0]


def pick_fusion_base_item(rng: random.Random, g: content_graph.Graph, target_ns: str, motif_words: set[str]) -> str:
    """Picks an existing lower-tier item capsule that can serve as a Terraria-style upgrade/fusion ingredient."""
    candidates: list[tuple[str, float]] = []
    for cid, d in g.items.items():
        rarity = str(d.get("meta", {}).get("rarity", "common"))
        if rarity in ("epic", "legendary"):
            continue
        m_tok, _ = g.tok.get(cid, (set(), set()))
        overlap = len(m_tok & motif_words)
        ns_bonus = 2.0 if cid.startswith(target_ns + "/") else 1.0
        candidates.append((cid, ns_bonus * (1.0 + 3.0 * overlap)))
    if not candidates:
        return "tools/crude_stone_pick"
    cids = [c for c, _ in candidates]
    weights = [w for _, w in candidates]
    return rng.choices(cids, weights=weights, k=1)[0]


def main() -> int:
    ap = argparse.ArgumentParser(description="Print a unique, synergy-steered design brief for one content session.")
    ap.add_argument("--seed", type=int, default=None, help="Deterministic seed (default: OS entropy).")
    ap.add_argument("--json", action="store_true", help="Emit JSON {suffix, mode, label, anchors, markdown} for the dispatcher.")
    ap.add_argument("--force-steward", action="store_true", help="Force the 1-in-10 Enterprise Steward & Connector mode.")
    args = ap.parse_args()
    rng = random.Random(args.seed) if args.seed is not None else random.SystemRandom()

    design = json.loads(DESIGN.read_text(encoding="utf-8"))
    frictions: dict[str, str] = design["frictions"]
    compat: dict[str, dict] = design.get("compatibility", {})
    path_types: dict[str, dict] = design["path_types"]
    disciplines: dict[str, dict] = design.get("crafting_disciplines", {})
    logic_tiers: dict[str, dict] = design.get("logic_tiers", {})

    g = content_graph.build()
    caps = g.caps
    claimed = load_inflight_anchors()

    friction_count = {f: 0 for f in frictions}
    path_count = {p: 0 for p in path_types}
    disc_count = {d_key: 0 for d_key in disciplines}
    cell_count: dict[tuple[str, str], int] = {}
    by_friction_names: dict[str, list[str]] = {f: [] for f in frictions}
    ns_count: dict[str, int] = {}

    for cid, data in caps.items():
        ns_count[cid.split("/")[0]] = ns_count.get(cid.split("/")[0], 0) + 1
        tags = set(data.get("tags", []))
        name = str(data.get("meta", {}).get("name", cid))
        fs = [f for f in frictions if f"solves_{f}" in tags]
        ps = [p for p in path_types if f"path_{p}" in tags]
        for d_key, d_spec in disciplines.items():
            if d_spec.get("tag") in tags:
                disc_count[d_key] += 1
        for f in fs:
            friction_count[f] += 1
            by_friction_names[f].append(name)
            for p in ps:
                cell_count[(f, p)] = cell_count.get((f, p), 0) + 1
        for p in ps:
            path_count[p] += 1

    flavor = rng.sample(design["flavor_words"], 2)
    suffix = "%04x" % rng.randrange(0x10000)
    rarity = rng.choices([r for r, _ in RARITIES], weights=[w for _, w in RARITIES], k=1)[0]
    band_name, band_ceiling, band_desc = rng.choices(BANDS, weights=BAND_WEIGHTS, k=1)[0]
    twist = rng.choice(design["twists"])

    # Roll the Munchkin Logic-Spectrum Tier (45% canonical, 30% plausible, 15% whimsical, 10% absurd)
    lt_keys = list(logic_tiers.keys()) or ["canonical"]
    lt_weights = [int(logic_tiers[k].get("weight", 25)) for k in lt_keys]
    chosen_logic_key = rng.choices(lt_keys, weights=lt_weights, k=1)[0]
    chosen_logic = logic_tiers.get(chosen_logic_key, {"tag": "logic_canonical", "hint": "Match material and function logically."})

    # Check if this session is the 1-in-10 Enterprise Steward & Synergy Connector session (or 1-in-50 Global Census)
    total_caps = len(caps)
    is_steward = args.force_steward or (total_caps > 0 and total_caps % 10 == 9)
    is_census = (total_caps > 0 and total_caps % 50 == 49)

    lines = ["# SESSION DESIGN BRIEF (generated by tools/pick_brief.py, do not commit)", ""]
    anchors: list[str] = []

    if is_steward:
        recent_9 = content_graph.recent_ids(9)
        orph_blocks = g.orphan_blocks()
        orph_npcs = g.orphan_npcs()
        pair = g.pick_pair(rng, "canonical", 600.0, claimed, hazard=False)
        v_anchor = pair[0] if pair else (orph_npcs[0] if orph_npcs else "npcs/anvil_smith_73cd")
        b_anchor = pair[1] if pair else (orph_blocks[0] if orph_blocks else "blocks/quill_ore_4083")
        b_secondary = orph_blocks[-1] if len(orph_blocks) > 1 and orph_blocks[-1] != b_anchor else "blocks/copper"
        fusion_item = recent_9[0] if recent_9 and recent_9[0].split("/")[0] not in ("blocks", "biomes", "npcs") else pick_fusion_base_item(rng, g, "devices", set())
        anchors = [v_anchor, b_anchor, b_secondary, fusion_item]

        fk = weighted_choice(rng, sorted(frictions), friction_count)
        disc_key = weighted_choice(rng, sorted(disciplines), disc_count) if disciplines else "terraria_item_fusion"
        disc = disciplines[disc_key]
        kind_label = "census_steward" if is_census else "steward_connector"
        meta = {"mode": kind_label, "label": f"steward/{disc_key}", "friction": fk, "anchors": anchors}

        lines += [
            f"**Mode:** {'GLOBAL 50-SESSION CENSUS & MASTERWORK SYNTHESIS' if is_census else '1-IN-10 ENTERPRISE STEWARD & SYNERGY CONNECTOR REVIEW'}",
            f"**Review Window (Past 9 Merged Capsules):** {', '.join(f'`{c}`' for c in recent_9) or 'baseline'}",
            f"**Current Orphan Blocks needing recipes ({len(orph_blocks)}):** {', '.join(f'`{b}`' for b in orph_blocks[:6]) or 'none'}",
            f"**Current Zero-Offer Specialist NPCs ({len(orph_npcs)}):** {', '.join(f'`{n}`' for n in orph_npcs[:6]) or 'none'}",
            "",
            "### Your 2-Part Steward Assignment:",
            f"1. **Keystone Connector Capsule (`{disc['namespace']}/<descriptive_slug>_{suffix}`):**",
            f"   - **Crafting Discipline:** {disc['title']} — {disc['hint']}",
            f"   - **Friction to ease:** `{fk}` — {frictions[fk]}",
            f"   - **Assigned Specialist Vendor (`offered_by.vendor`):** `{v_anchor}`",
            f"   - **Assigned Multi-Ingredient Recipe (`offered_by.price`):** Must combine `{b_anchor}` + `{b_secondary}` (or `{fusion_item}` + `{b_anchor}`) so previously isolated strata and items become deeply interconnected!",
            f"   - **Mechanical Synergy Requirement:** Include at least one modifier or reaction that specifically interacts with `{b_anchor}` (e.g. bonus when `tile.block_id == '{b_anchor}'`, or `consume_item` / `spawn_item` refinement).",
            f"   - **Required tags:** `solves_{fk}`, `{disc['tag']}`, `logic_canonical`, `steward_keystone`.",
            f"2. **Optional Enterprise Review Note (`proposals/steward_review_{suffix}.md`, <= 8 KB):**",
            "   - Briefly note how the past 9 capsules fit together, highlight any standout synergies, and explain how your Keystone Connector bridges the gap.",
            "   - **Law L2/L4 Reminder:** Never modify or delete existing capsules; all stewardship is forward-only via your new Keystone Connector capsule (and optional proposal note).",
        ]
    elif rng.random() < WORLD_MODE_PROB:
        world = design["world_archetypes"]
        orph_blocks = g.orphan_blocks()
        orph_npcs = g.orphan_npcs()
        # Smart Orphan Throttling: don't mint more blocks/NPCs while existing ones are unreferenced
        candidates = sorted(world.keys())
        if len(orph_blocks) >= 3 and "block" in candidates:
            candidates.remove("block")
        if len(orph_npcs) >= 2 and "npc" in candidates:
            candidates.remove("npc")
        if not candidates:
            candidates = ["biome"]

        kind = weighted_choice(rng, candidates, {k: ns_count.get(world[k]["namespace"], 0) for k in candidates})
        w = world[kind]
        meta = {"mode": "world", "label": f"world/{kind}", "anchors": []}
        lines += [
            "**Mode:** WORLD-BUILDING (Rare Exclusive NPCs, Pocket Mines & Strata)",
            f"**Archetype:** `{kind}`   **Namespace:** `{w['namespace']}`",
            f"**Capsule id:** `{w['namespace']}/<descriptive_slug>_{suffix}`  (slug MUST end with `_{suffix}`)",
            f"**Imitate structure of:** `{w['example']}`   **Rarity:** {rarity}",
            f"**Guidance:** {w['hint']}",
            f"**Optional motif words (use 0-1 if fitting, never force):** {', '.join(flavor)}",
            "**Tags to include:** `world_" + kind + "` plus descriptive motif/specialty tags.",
        ]
        if kind == "biome":
            under_blocks = (orph_blocks + [b for b in g.blocks if b not in orph_blocks and b not in content_graph.STARTER_BLOCKS])[:4]
            anchors = under_blocks
            meta["anchors"] = anchors
            lines.append(
                f"**Mandatory Synergy (`biome_weights`):** Weave at least 2 of these under-referenced blocks into `biome_weights` (alongside `blocks/stone`): "
                + ", ".join(f"`{b}`" for b in under_blocks)
            )
        lines += [
            "",
            "**World-building rules recap:**",
            "- Do NOT include `offered_by` on `block`, `biome`, or `npc` capsules.",
            "- If `block`: include `mineable_block` (and `carry`, `sell` if collectible), `stats` (`base_hp`, `value_base`, `spawn_prob` 0.005..0.015, `z_unlock`, `z_max`, `ideal_tool`), and `biome_weights`.",
            "- If `biome`: include `biome_profile`, `stats` (`z_min`, `z_max`, `biome_weight`), and `biome_weights` mapping existing `blocks/*` ids to weights.",
            "- If `npc`: include `npc_vendor` and `stats` (`unlock_depth`); give them a clear guild/artisan specialty in `tags` and `meta.description`.",
            "- Never edit another capsule, `engine/`, `vocab/`, `tools/` or `tests/`.",
        ]
    else:
        fk = weighted_choice(rng, sorted(frictions), friction_count)
        raw_allowed = compat.get(fk, {}).get("paths", sorted(path_types))
        allowed_paths = [p for p in raw_allowed if p in path_types] or sorted(path_types)
        pk = weighted_choice(rng, allowed_paths, {p: cell_count.get((fk, p), 0) for p in allowed_paths})
        pt = path_types[pk]

        # Also pick a Multi-Disciplinary Crafting Discipline compatible with the path or weighted by coverage
        disc_key = weighted_choice(rng, sorted(disciplines), disc_count)
        disc = disciplines[disc_key]
        # Prefer the discipline's archetype/namespace 50% of the time so all 10 crafting disciplines flourish
        use_disc_arch = rng.random() < 0.55
        target_arch = disc["archetype"] if use_disc_arch else pt["archetype"]
        target_ns = disc["namespace"] if use_disc_arch else pt["namespace"]

        # Pick logic-matched (Vendor, Primary Ore) pair from content_graph
        want_hazard = fk in ("hazard_clearing", "fluid_flooding")
        pair = g.pick_pair(rng, chosen_logic_key, band_ceiling, claimed, hazard=want_hazard)
        if not pair:
            pair = g.pick_pair(rng, chosen_logic_key, 600.0, claimed, hazard=False)
        v_anchor = pair[0] if pair else "npcs/anvil_smith_73cd"
        b_anchor = pair[1] if pair else "blocks/quill_ore_4083"

        # Secondary ingredient: either a second block or (for Terraria fusion) an existing item capsule
        v_motifs = g.tok.get(v_anchor, (set(), set()))[0] | g.tok.get(b_anchor, (set(), set()))[0]
        if disc_key == "terraria_item_fusion":
            second_ingredient = pick_fusion_base_item(rng, g, target_ns, v_motifs)
            recipe_hint = (
                f"Include BOTH `{second_ingredient}` (qty 1) AND `{b_anchor}` (qty 10-80) inside `offered_by[0].price` "
                f"(Terraria-style item + ore fusion at `{v_anchor}`)."
            )
        else:
            other_blocks = [b for b in g.block_candidates(band_ceiling, claimed, False) if b != b_anchor]
            second_ingredient = other_blocks[0] if other_blocks else "blocks/copper"
            recipe_hint = (
                f"Price this crafted capsule at `{v_anchor}` (`offered_by[0].vendor`) using `{b_anchor}` as the primary reagent "
                f"plus `{second_ingredient}` as a secondary flux/reagent in `offered_by[0].price`."
            )

        anchors = [v_anchor, b_anchor, second_ingredient]
        mech_hint = compat.get(fk, {}).get("mechanics", "")
        existing_names = by_friction_names[fk][-6:]
        meta = {
            "mode": "solution",
            "label": f"{fk} via {disc_key}",
            "friction": fk,
            "path": pk,
            "discipline": disc_key,
            "logic_tier": chosen_logic_key,
            "anchors": anchors,
        }
        lines += [
            "**Mode:** MULTI-DISCIPLINARY CRAFT & SOLUTION",
            f"**Crafting Discipline:** `{disc_key}` ({disc['title']}) — {disc['hint']}",
            f"**Friction to ease:** `{fk}` — {frictions[fk]}",
            f"**Solution path:** `{pk}` — {pt['hint']}",
            f"**Archetype:** `{target_arch}`   **Namespace:** `{target_ns}`",
            f"**Capsule id:** `{target_ns}/<descriptive_slug>_{suffix}`  (slug MUST end with `_{suffix}`)",
            f"**Imitate structure of:** `{pt['example']}`",
            f"**Rarity:** {rarity}   **Era:** {band_name} ({band_desc})",
            "",
            "### Mandatory Synergy & Logic Connector Assignment:",
            f"- **Logic Spectrum Tier (`{chosen_logic['tag']}`):** {chosen_logic['hint']}",
            f"- **Assigned Specialist Artisan / Vendor (`offered_by[0].vendor`):** `{v_anchor}` (do NOT default to `npcs/peddler_vayne` unless assigned)",
            f"- **Assigned Multi-Ingredient Recipe (`offered_by[0].price`):** {recipe_hint}",
            f"- **Stratum / Ingredient Interaction:** If natural for your design, let a modifier or reaction reward or interact with `{b_anchor}` (e.g. bonus when `tile.block_id == '{b_anchor}'`, or consuming/spawning `{b_anchor}`).",
        ]
        if mech_hint:
            lines.append(f"- **Mechanical hook hint:** {mech_hint}")
        lines += [
            f"- **Optional motif words (use 0-1 if fitting, never force):** {', '.join(flavor)}",
            f"- **Twist:** {twist}",
            f"- **Required tags:** `solves_{fk}`, `path_{pk}`, `{disc['tag']}`, `{chosen_logic['tag']}` (plus descriptive tags).",
            f"- **Existing concept names for this friction (do not duplicate concept):** "
            + (", ".join(f'"{n}"' for n in existing_names) or "none yet"),
            "",
            "**Rules recap:** ease is earned, never given; include at least one working modifier or reaction that genuinely eases the friction; "
            "one clear limiter (cost, durability/charge, or condition); never set `yield_mult <= 0` unless spawning a real non-dirt item; "
            "edges point backward (`offered_by` inside YOUR capsule pointing to the assigned `npcs/*` vendor and existing ingredient IDs); "
            "never edit another capsule, `engine/`, `vocab/`, `tools/` or `tests/`.",
        ]

    if args.json:
        print(json.dumps({"suffix": suffix, **meta, "markdown": "\n".join(lines)}))
    else:
        print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
