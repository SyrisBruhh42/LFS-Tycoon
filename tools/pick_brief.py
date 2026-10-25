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
        if g.is_skill_or_station_node(cid):
            continue
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


def pick_skill_prerequisite(
    rng: random.Random, g: content_graph.Graph, ceiling: float, motif_words: set[str], claimed: set[str]
) -> dict | None:
    """Picks a live Skill Bracket or Workshop Station capsule to serve as a non-consumed prerequisite in offered_by[].price."""
    nodes = g.skill_bracket_nodes(ceiling)
    if not nodes:
        return None
    scored: list[tuple[dict, float]] = []
    for n in nodes:
        cid = n["id"]
        m_tok, _ = g.tok.get(cid, (set(), set()))
        overlap = len(m_tok & motif_words)
        explicit_boost = 6.0 if n["explicit_skill"] else 1.0
        claim_pen = 3 if cid in claimed else 0
        underuse_weight = 1.0 / (1.0 + n["dependent_count"] + claim_pen) ** 2
        scored.append((n, explicit_boost * (1.0 + 2.5 * overlap) * underuse_weight))
    choices = [x[0] for x in scored]
    weights = [x[1] for x in scored]
    return rng.choices(choices, weights=weights, k=1)[0]


def resolve_theme(
    rng: random.Random, design_themes: dict[str, dict], g: content_graph.Graph, motif_words: set[str], logic_key: str
) -> tuple[str, dict]:
    """Matches motif words against both seed themes and Jules-created theme_<slug> tags."""
    if logic_key == "absurd" and "theme_munchkin_paradox" in design_themes:
        return "theme_munchkin_paradox", design_themes["theme_munchkin_paradox"]

    all_themes: dict[str, dict] = dict(design_themes)
    for t_tag, t_info in g.discovered_themes().items():
        if t_tag not in all_themes:
            slug_words = [w for w in t_tag[len("theme_"):].split("_") if len(w) >= 3]
            all_themes[t_tag] = {
                "title": f"Emergent Subterranean Theme ({t_tag})",
                "motifs": slug_words,
                "lore": f"Player/Jules-discovered subterranean faction & crafting school ({t_info['member_count']} capsules across brackets {t_info['brackets']}).",
            }

    best_k = "theme_tectonic_crucible"
    scored: list[tuple[str, float]] = []
    for tk, t_spec in all_themes.items():
        t_motifs = set(t_spec.get("motifs", []))
        overlap = sum(1 for m in motif_words if any(content_graph._match(m, tm) for tm in t_motifs))
        scored.append((tk, 1.0 + 4.0 * overlap))
    if scored:
        keys = [k for k, _ in scored]
        weights = [w for _, w in scored]
        best_k = rng.choices(keys, weights=weights, k=1)[0]
    return best_k, all_themes[best_k]


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
    skill_brackets_cfg: dict[str, dict] = design.get("modular_skill_brackets", {})
    endgame_themes: dict[str, dict] = design.get("endgame_themes", {})

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
        v_motifs = g.tok.get(v_anchor, (set(), set()))[0] | g.tok.get(b_anchor, (set(), set()))[0]
        theme_key, theme_spec = resolve_theme(rng, endgame_themes, g, v_motifs, "canonical")
        skill_node = pick_skill_prerequisite(rng, g, 600.0, v_motifs, claimed)
        skill_req_id = skill_node["id"] if skill_node else "upgrades/surveyor_chalk_and_stencil"
        skill_school_tag = skill_node["school"] if skill_node else f"skill_school_{b_anchor.split('/')[-1].split('_')[0]}"
        bracket_num = min(5, (skill_node["bracket"] + 1) if skill_node else 2)
        bracket_tag = f"bracket_{bracket_num}"
        anchors = [v_anchor, b_anchor, b_secondary, skill_req_id]

        fk = weighted_choice(rng, sorted(frictions), friction_count)
        disc_key = weighted_choice(rng, sorted(disciplines), disc_count) if disciplines else "terraria_item_fusion"
        disc = disciplines[disc_key]
        kind_label = "census_steward" if is_census else "steward_connector"
        meta = {
            "mode": kind_label,
            "label": f"steward/{disc_key}",
            "friction": fk,
            "theme": theme_key,
            "bracket": bracket_tag,
            "anchors": anchors,
        }

        lines += [
            f"**Mode:** {'GLOBAL 50-SESSION CENSUS & MASTERWORK SYNTHESIS' if is_census else '1-IN-10 ENTERPRISE STEWARD & SYNERGY CONNECTOR REVIEW'}",
            f"**Review Window (Past 9 Merged Capsules):** {', '.join(f'`{c}`' for c in recent_9) or 'baseline'}",
            f"**Current Orphan Blocks needing recipes ({len(orph_blocks)}):** {', '.join(f'`{b}`' for b in orph_blocks[:6]) or 'none'}",
            f"**Current Zero-Offer Specialist NPCs ({len(orph_npcs)}):** {', '.join(f'`{n}`' for n in orph_npcs[:6]) or 'none'}",
            f"**Endgame Lore Theme (`{theme_key}`):** *{theme_spec['title']}* — {theme_spec['lore']}",
            f"**Modular Skill School & Bracket:** `{skill_school_tag}` (`{bracket_tag}`)",
            "",
            "### Your 2-Part Steward Assignment:",
            f"1. **Keystone Connector Capsule (`{disc['namespace']}/<descriptive_slug>_{suffix}`):**",
            f"   - **Crafting Discipline:** {disc['title']} — {disc['hint']}",
            f"   - **Friction to ease:** `{fk}` — {frictions[fk]}",
            f"   - **Assigned Specialist Vendor (`offered_by.vendor`):** `{v_anchor}`",
            f"   - **Modular Skill Bracket Requirement (`offered_by.price`):** Include `\"{skill_req_id}\": 1` (non-consumed permanent skill/station requirement!) PLUS `{b_anchor}` and `{b_secondary}` in `offered_by[0].price` so skill brackets, specialist NPCs, and orphan strata lock together!",
            f"   - **Mechanical Synergy Requirement:** Include at least one modifier or reaction that specifically interacts with `{b_anchor}` (e.g. bonus when `tile.block_id == '{b_anchor}'`, or `consume_item` / `spawn_item` refinement).",
            f"   - **Required tags:** `solves_{fk}`, `{disc['tag']}`, `{bracket_tag}`, `{skill_school_tag}`, `{theme_key}`, `logic_canonical`, `steward_keystone`.",
            f"2. **Optional Enterprise Review Note (`proposals/steward_review_{suffix}.md`, <= 8 KB):**",
            "   - Briefly note how the past 9 capsules, skill brackets, and themes fit together, and explain how your Keystone Connector bridges the gap.",
            "   - **Law L2/L4 Reminder:** Never modify or delete existing capsules; all stewardship is forward-only via your new Keystone Connector capsule (and optional proposal note).",
        ]
    elif rng.random() < WORLD_MODE_PROB:
        world = design["world_archetypes"]
        orph_blocks = g.orphan_blocks()
        orph_npcs = g.orphan_npcs()
        candidates = sorted(world.keys())
        if len(orph_blocks) >= 3 and "block" in candidates:
            candidates.remove("block")
        if len(orph_npcs) >= 2 and "npc" in candidates:
            candidates.remove("npc")
        if not candidates:
            candidates = ["biome"]

        kind = weighted_choice(rng, candidates, {k: ns_count.get(world[k]["namespace"], 0) for k in candidates})
        w = world[kind]
        theme_key, theme_spec = resolve_theme(rng, endgame_themes, g, set(flavor), "canonical")
        meta = {"mode": "world", "label": f"world/{kind}", "theme": theme_key, "anchors": []}
        lines += [
            "**Mode:** WORLD-BUILDING (Rare Exclusive NPCs, Pocket Mines & Strata)",
            f"**Archetype:** `{kind}`   **Namespace:** `{w['namespace']}`",
            f"**Capsule id:** `{w['namespace']}/<descriptive_slug>_{suffix}`  (slug MUST end with `_{suffix}`)",
            f"**Imitate structure of:** `{w['example']}`   **Rarity:** {rarity}",
            f"**Lore & Endgame Theme (`{theme_key}`):** *{theme_spec['title']}* — {theme_spec['lore']} (or mint a brand-new `theme_<slug>` tag if founding a distinct subterranean enclave!)",
            f"**Guidance:** {w['hint']}",
            f"**Optional motif words (use 0-1 if fitting, never force):** {', '.join(flavor)}",
            f"**Tags to include:** `world_{kind}`, `{theme_key}` (or your new `theme_<slug>`) plus descriptive motif/specialty tags.",
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

        disc_key = weighted_choice(rng, sorted(disciplines), disc_count)
        disc = disciplines[disc_key]
        use_disc_arch = rng.random() < 0.60 or disc_key == "rpg_skill_mastery_tree"
        target_arch = disc["archetype"] if use_disc_arch else pt["archetype"]
        target_ns = disc["namespace"] if use_disc_arch else pt["namespace"]

        want_hazard = fk in ("hazard_clearing", "fluid_flooding")
        pair = g.pick_pair(rng, chosen_logic_key, band_ceiling, claimed, hazard=want_hazard)
        if not pair:
            pair = g.pick_pair(rng, chosen_logic_key, 600.0, claimed, hazard=False)
        v_anchor = pair[0] if pair else "npcs/anvil_smith_73cd"
        b_anchor = pair[1] if pair else "blocks/quill_ore_4083"

        v_motifs = g.tok.get(v_anchor, (set(), set()))[0] | g.tok.get(b_anchor, (set(), set()))[0]
        theme_key, theme_spec = resolve_theme(rng, endgame_themes, g, v_motifs, chosen_logic_key)

        # Determine Modular Skill Bracket & Skill School assignment
        expandable_schools = g.expandable_skill_schools(band_ceiling)
        skill_node = pick_skill_prerequisite(rng, g, band_ceiling, v_motifs, claimed)
        extra_req_tags: list[str] = [theme_key]

        if disc_key == "rpg_skill_mastery_tree":
            # Jules is creating a NEW Modular Skill Bracket node!
            if expandable_schools and rng.random() < 0.60:
                exp = rng.choice(expandable_schools)
                bracket_num = exp["next_bracket"]
                bracket_tag = f"bracket_{bracket_num}"
                school_tag = exp["school"]
                prev_skill_id = exp["prev_capsule_id"]
                second_ingredient = prev_skill_id
                skill_brief_line = (
                    f"**EXPANDING MODULAR SKILL SCHOOL (`{school_tag}` -> `{bracket_tag}`):** You are creating Bracket {bracket_num} of `{school_tag}`! "
                    f"Require the previous bracket capsule `\"{prev_skill_id}\": 1` (non-consumed!) plus `{b_anchor}` inside `offered_by[0].price`. "
                    f"Future recipes will reference YOUR new capsule ID as their `{bracket_tag}` skill requirement!"
                )
                recipe_hint = (
                    f"At `{v_anchor}` (`offered_by[0].vendor`), set `offered_by[0].price` to require `\"{prev_skill_id}\": 1` "
                    f"(the preceding skill bracket) AND `{b_anchor}` (qty 20-90)."
                )
            else:
                bracket_num = 1 if band_name == "early" else (2 if band_name == "mid" else 3)
                bracket_tag = f"bracket_{bracket_num}"
                ore_stem = b_anchor.split("/")[-1].split("_")[0]
                school_tag = f"skill_school_{ore_stem}_{flavor[0]}"
                other_blocks = [b for b in g.block_candidates(band_ceiling, claimed, False) if b != b_anchor]
                second_ingredient = other_blocks[0] if other_blocks else "blocks/copper"
                skill_brief_line = (
                    f"**FOUNDING NEW MODULAR SKILL BRACKET (`{school_tag}`, `{bracket_tag}`):** You are founding a new expandable Skill Bracket node! "
                    f"Tag this capsule with `\"skill_bracket\"`, `\"{bracket_tag}\"`, `\"{school_tag}\"`, and `\"{theme_key}\"` (or mint a new `skill_school_<slug>` / `theme_<slug>` tag if fitting). "
                    f"Subsequent Jules sessions will automatically discover your capsule and gate higher-tier recipes behind it!"
                )
                recipe_hint = (
                    f"At `{v_anchor}` (`offered_by[0].vendor`), price this Skill Bracket unlock using `{b_anchor}` and `{second_ingredient}` in `offered_by[0].price`."
                )
            extra_req_tags.extend(["skill_bracket", bracket_tag, school_tag])
        elif disc_key == "terraria_item_fusion":
            second_ingredient = pick_fusion_base_item(rng, g, target_ns, v_motifs)
            bracket_num = min(5, max(2, (skill_node["bracket"] + 1) if skill_node else 2))
            bracket_tag = f"bracket_{bracket_num}"
            school_tag = skill_node["school"] if skill_node else f"skill_school_{b_anchor.split('/')[-1].split('_')[0]}"
            if skill_node and band_name != "early":
                skill_id = skill_node["id"]
                skill_brief_line = (
                    f"**Assigned Modular Skill Bracket (`{bracket_tag}` in `{school_tag}`):** Gate this fusion recipe behind `{skill_id}` "
                    f"(`{skill_node['name']}`, non-consumed in engine) + consumed base item `{second_ingredient}` + `{b_anchor}`!"
                )
                recipe_hint = (
                    f"In `offered_by[0].price` at `{v_anchor}`, include `\"{skill_id}\": 1` (permanent skill/station requirement), "
                    f"`\"{second_ingredient}\": 1` (consumed base gear whose sockets transfer!), and `\"{b_anchor}\"` (qty 15-90)."
                )
            else:
                skill_brief_line = f"**Assigned Modular Skill Bracket (`{bracket_tag}` in `{school_tag}`):** Cumulative Terraria-style fusion tier."
                recipe_hint = (
                    f"Include BOTH `{second_ingredient}` (qty 1) AND `{b_anchor}` (qty 10-80) inside `offered_by[0].price` "
                    f"(Terraria-style item + ore fusion at `{v_anchor}`)."
                )
            extra_req_tags.extend([bracket_tag, school_tag])
        else:
            other_blocks = [b for b in g.block_candidates(band_ceiling, claimed, False) if b != b_anchor]
            second_ingredient = other_blocks[0] if other_blocks else "blocks/copper"
            if skill_node and (band_name != "early" or skill_node["explicit_skill"] or rng.random() < 0.55):
                skill_id = skill_node["id"]
                bracket_num = skill_node["bracket"]
                bracket_tag = f"bracket_{bracket_num}"
                school_tag = skill_node["school"]
                second_ingredient = skill_id
                skill_brief_line = (
                    f"**Assigned Modular Skill Bracket (`{bracket_tag}` — `{school_tag}`):** This recipe belongs to `{school_tag}` (`{bracket_tag}`) "
                    f"and requires `{skill_id}` (`{skill_node['name']}`, verified & kept permanently by the engine when forging!)."
                )
                recipe_hint = (
                    f"Price this crafted capsule at `{v_anchor}` (`offered_by[0].vendor`) with `\"{skill_id}\": 1` (non-consumed Skill Bracket / Station requirement) "
                    f"PLUS `{b_anchor}` as the primary stratum ore in `offered_by[0].price`."
                )
            else:
                bracket_num = 1
                bracket_tag = "bracket_1"
                school_tag = f"skill_school_{b_anchor.split('/')[-1].split('_')[0]}"
                skill_brief_line = (
                    f"**Assigned Modular Skill Bracket (`bracket_1` Novice — `{school_tag}`):** Entry-bracket recipe that players can forge before unlocking higher Skill Brackets."
                )
                recipe_hint = (
                    f"Price this crafted capsule at `{v_anchor}` (`offered_by[0].vendor`) using `{b_anchor}` as the primary reagent "
                    f"plus `{second_ingredient}` as a secondary flux/reagent in `offered_by[0].price`."
                )
            extra_req_tags.extend([bracket_tag, school_tag])

        anchors = [v_anchor, b_anchor, second_ingredient]
        mech_hint = compat.get(fk, {}).get("mechanics", "")
        existing_names = by_friction_names[fk][-6:]
        b_cfg = skill_brackets_cfg.get(bracket_tag, {})
        epoch_title = b_cfg.get("lore_epoch", "The Great Ledger Beneath")
        meta = {
            "mode": "solution",
            "label": f"{fk} via {disc_key} ({bracket_tag})",
            "friction": fk,
            "path": pk,
            "discipline": disc_key,
            "bracket": bracket_tag,
            "skill_school": school_tag,
            "theme": theme_key,
            "logic_tier": chosen_logic_key,
            "anchors": anchors,
        }
        req_tags_str = ", ".join(f"`{t}`" for t in ([f"solves_{fk}", f"path_{pk}", disc["tag"], chosen_logic["tag"]] + extra_req_tags))
        lines += [
            "**Mode:** MULTI-DISCIPLINARY CRAFT, SKILL BRACKET & LORE SYNERGY",
            f"**Crafting Discipline:** `{disc_key}` ({disc['title']}) — {disc['hint']}",
            f"**Endgame Lore Theme (`{theme_key}`):** *{theme_spec['title']}* — {theme_spec['lore']}",
            f"**Geological Lore Epoch:** {epoch_title}",
            f"- {skill_brief_line}",
            f"**Friction to ease:** `{fk}` — {frictions[fk]}",
            f"**Solution path:** `{pk}` — {pt['hint']}",
            f"**Archetype:** `{target_arch}`   **Namespace:** `{target_ns}`",
            f"**Capsule id:** `{target_ns}/<descriptive_slug>_{suffix}`  (slug MUST end with `_{suffix}`)",
            f"**Imitate structure of:** `{pt['example']}`",
            f"**Rarity:** {rarity}   **Era:** {band_name} ({band_desc})",
            "",
            "### Mandatory Synergy, Skill Bracket & Logic Connector Assignment:",
            f"- **Logic Spectrum Tier (`{chosen_logic['tag']}`):** {chosen_logic['hint']}",
            f"- **Assigned Specialist Artisan / Vendor (`offered_by[0].vendor`):** `{v_anchor}` (do NOT default to `npcs/peddler_vayne` unless assigned)",
            f"- **Assigned Multi-Ingredient Recipe (`offered_by[0].price`):** {recipe_hint}",
            f"- **Deep Lore & Stratum Interconnectivity:** Weave the lore of *{theme_spec['title']}* (`{theme_key}`), `{v_anchor}`, and `{b_anchor}` into `meta.description`, and if natural let a modifier or reaction reward or interact with `{b_anchor}`.",
        ]
        if mech_hint:
            lines.append(f"- **Mechanical hook hint:** {mech_hint}")
        lines += [
            f"- **Optional motif words (use 0-1 if fitting, never force):** {', '.join(flavor)}",
            f"- **Twist:** {twist}",
            f"- **Required tags:** {req_tags_str} (you may also add a new `skill_school_<slug>` or `theme_<slug>` tag if introducing an expandable sub-discipline).",
            f"- **Existing concept names for this friction (do not duplicate concept):** "
            + (", ".join(f'"{n}"' for n in existing_names) or "none yet"),
            "",
            "**Rules recap:** ease is earned, never given; include at least one working modifier or reaction that genuinely eases the friction; "
            "one clear limiter (cost, durability/charge, or condition); never set `yield_mult <= 0` unless spawning a real non-dirt item; "
            "edges point backward (`offered_by` inside YOUR capsule pointing to the assigned `npcs/*` vendor and existing ingredient/skill IDs); "
            "never edit another capsule, `engine/`, `vocab/`, `tools/` or `tests/`.",
        ]

    if args.json:
        print(json.dumps({"suffix": suffix, **meta, "markdown": "\n".join(lines)}))
    else:
        print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
