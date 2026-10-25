#!/usr/bin/env python3
"""Content graph, synergy scorecard and the logic-affinity connector (stdlib only, read-only).

One graph, many consumers: the brief picker, the CI gate, the steward review lane and the release promoter
all ask this module "what is connected to what, and how sensibly?".

Edges are FUNCTIONAL only (offered_by, price keys, biome_weights, and block ids inside modifiers/reactions).
Words in `tags` or `meta.description` never create an edge.

Logic affinity (the "connector"): how sensible is a link between two capsules?
  +3 per shared motif word (max 2)   e.g. `rivet_assayer` <-> `rivet_ore`  (stem match, len>=4: anvil ~ anvilstone)
  +1 shared material family          ore / metal / soil / stone / gravel / fluid / hazard
  +1 tool fit                        item.tool_type == block.ideal_tool
  tier: >=3 canonical, >=1 plausible, 0 loose (whimsical or absurd, told apart only by the author's declared tag)

Usage: python3 tools/content_graph.py [--json] [--recent N]
"""
from __future__ import annotations

import argparse
import json
import math
import re
import subprocess
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

ROOT = Path(__file__).resolve().parent.parent
CAPSULES_DIR = ROOT / "content" / "capsules"
PACING_FILE = ROOT / "design" / "pacing.json"
HEALTH_BASELINE_FILE = ROOT / "design" / "health_baseline.json"
WORLD_NS = {"blocks", "biomes", "npcs"}
STARTER_BLOCKS = {"blocks/copper", "blocks/dirt", "blocks/stone"}
LOGIC_TIERS = ("canonical", "plausible", "whimsical", "absurd")
BLOCK_RE = re.compile(r"blocks/[a-z0-9_]+")
DEPTH_RE = re.compile(r"player\.max_depth\s*>=?\s*(\d+(?:\.\d+)?)")
HEX4 = re.compile(r"^[0-9a-f]{4}$")
STEWARD_FOOTER_RE = re.compile(r"<!--\s*steward-audit:\s*(.*?)\s*-->", re.DOTALL)
GENERIC = {"block", "world", "npc", "vendor", "town", "backfill", "mineral", "catalyst", "heat", "source", "strict",
           "locked", "disposable", "the", "and", "for", "ore", "item", "tool"}
CATEGORY = {"ore", "metal", "soil", "stone", "gravel", "fluid", "hazard"}
SKIP_TAG_PREFIX = ("logic_", "solves_", "path_", "world_")
AHEAD_SLACK = 25  # a priced ore may unlock this much deeper than the offer before we call it ahead-of-curve
CAT_WORDS = CATEGORY | {"mineral"}


class CapsuleNode(dict):
    """Dict subclass representing a capsule that also exposes .id, .ns, and .raw for object-style access."""

    def __init__(self, cid: str, data: dict):
        super().__init__(data)
        self.id = cid
        self.cid = cid
        self.ns = cid.split("/", 1)[0] if "/" in cid else ""

    @property
    def raw(self) -> dict:
        return self

    @property
    def stats(self) -> dict:
        return self.get("stats", {}) or {}

    @property
    def tags(self) -> list:
        return self.get("tags", []) or []

    @property
    def meta(self) -> dict:
        return self.get("meta", {}) or {}

    @property
    def offered_by(self) -> list:
        return self.get("offered_by", []) or []

    @property
    def affordances(self) -> list:
        return self.get("affordances", []) or []


def load_capsules() -> dict[str, dict]:
    out: dict[str, dict] = {}
    for p in sorted(CAPSULES_DIR.glob("*/*/capsule.json")):
        try:
            cid = f"{p.parent.parent.name}/{p.parent.name}"
            out[cid] = CapsuleNode(cid, json.loads(p.read_text(encoding="utf-8")))
        except Exception:
            continue
    return out


def _load_json_safe(path: Path, default: dict) -> dict:
    try:
        if path.exists():
            return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        pass
    return default


def parse_steward_footer(text: str) -> Optional[Dict[str, Any]]:
    """Parses `<!-- steward-audit: {...} -->` JSON footer blocks from Steward proposal/PR text."""
    if not isinstance(text, str) or not text:
        return None
    m = STEWARD_FOOTER_RE.search(text)
    if not m:
        return None
    try:
        parsed = json.loads(m.group(1).strip())
        return parsed if isinstance(parsed, dict) else None
    except Exception:
        return None


def token_sets(cid: str, data: dict) -> tuple[set[str], set[str]]:
    """(motif words, material-family words) derived from the id slug and tags."""
    slug = cid.split("/", 1)[1]
    raw: set[str] = {p for p in slug.split("_") if p and not HEX4.match(p)}
    for t in data.get("tags", []) or []:
        if isinstance(t, str) and not t.startswith(SKIP_TAG_PREFIX):
            raw.add(t)
            raw.update(x for x in t.split("_") if x)
    cats = {t for t in raw if t in CAT_WORDS}
    motif = {t for t in raw if len(t) >= 3 and t not in GENERIC and t not in CAT_WORDS}
    return motif, cats


def _match(a: str, b: str) -> bool:
    return a == b or (len(a) >= 4 and len(b) >= 4 and (a.startswith(b) or b.startswith(a)))


def affinity(ma: set[str], ca: set[str], mb: set[str], cb: set[str], tool_fit: bool = False) -> int:
    shared = sum(1 for x in ma if any(_match(x, y) for y in mb))
    return min(shared, 2) * 3 + (1 if ca & cb else 0) + (1 if tool_fit else 0)


def tier_of(score: int) -> str:
    return "canonical" if score >= 3 else ("plausible" if score >= 1 else "loose")


def declared_tier(data: dict) -> str | None:
    found = [t[len("logic_"):] for t in data.get("tags", []) or []
             if isinstance(t, str) and t.startswith("logic_") and t[len("logic_"):] in LOGIC_TIERS]
    return found[0] if len(found) == 1 else None


def recent_ids(n: int) -> list[str]:
    """Capsule ids by add-commit recency, newest first (best effort; empty when git history is unavailable)."""
    try:
        out = subprocess.run(["git", "log", "--diff-filter=A", "--name-only", "--pretty=format:", "-n", str(max(n * 6, 60)),
                              "--", "content/capsules"], cwd=ROOT, capture_output=True, text=True, timeout=60).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    ids: list[str] = []
    for line in out.splitlines():
        m = re.match(r"content/capsules/([a-z0-9_]+)/([a-z0-9_]+)/capsule\.json$", line.strip())
        if m and f"{m.group(1)}/{m.group(2)}" not in ids:
            ids.append(f"{m.group(1)}/{m.group(2)}")
    return ids[:n]


class Graph:
    def __init__(self, caps: dict[str, dict] | None = None):
        raw_caps = caps if caps is not None else load_capsules()
        self.caps: dict[str, CapsuleNode] = {
            c: (d if isinstance(d, CapsuleNode) else CapsuleNode(c, d))
            for c, d in raw_caps.items()
        }
        self.capsules = self.caps
        self.by_ns: dict[str, list[CapsuleNode]] = defaultdict(list)
        for cid, node in sorted(self.caps.items()):
            self.by_ns[cid.split("/", 1)[0]].append(node)
        self.blocks = {c: d for c, d in self.caps.items() if c.startswith("blocks/")}
        self.npcs = {c: d for c, d in self.caps.items() if c.startswith("npcs/")}
        self.biomes = {c: d for c, d in self.caps.items() if c.startswith("biomes/")}
        self.items = {c: d for c, d in self.caps.items() if c.split("/")[0] not in WORLD_NS}
        self.tok = {c: token_sets(c, d) for c, d in self.caps.items()}
        self.offers: list[dict] = []
        self.all_offers: list[dict] = []
        self.vendor_offers: Counter = Counter()
        self.price_use: Counter = Counter()
        self.consumers: dict[str, set[str]] = defaultdict(set)
        self.item_vendors: dict[str, set[str]] = defaultdict(set)
        self.item_blocks: dict[str, set[str]] = defaultdict(set)
        self.item_prereqs: dict[str, set[str]] = defaultdict(set)
        self.prereq_dependents: dict[str, set[str]] = defaultdict(set)
        self.item_min_depth: dict[str, float] = {}
        self._index()

    # ---- construction
    def _npc_depth(self, vid: str) -> float:
        v = self.npcs.get(vid, {}).get("stats", {}).get("unlock_depth")
        return float(v) if isinstance(v, (int, float)) else 0.0

    def _index(self) -> None:
        for cid, d in self.caps.items():
            for off in d.get("offered_by", []) or []:
                if not isinstance(off, dict):
                    continue
                vid = str(off.get("vendor", ""))
                gate = 0.0
                m = DEPTH_RE.search(str(off.get("unlock_if", "")))
                if m:
                    gate = float(m.group(1))
                eff_d = max(self._npc_depth(vid), gate)
                price = {k: v for k, v in (off.get("price", {}) or {}).items()}
                self.all_offers.append({"item": cid, "vendor": vid, "price": price, "depth": eff_d})

        for cid, d in self.items.items():
            body = json.dumps({"m": d.get("modifiers", []), "r": d.get("reactions", [])})
            for b in set(BLOCK_RE.findall(body)):
                if b in self.blocks:
                    self.item_blocks[cid].add(b)
                    self.consumers[b].add(cid)
            min_d: float | None = None
            for off in d.get("offered_by", []) or []:
                vid = str(off.get("vendor", ""))
                gate = 0.0
                m = DEPTH_RE.search(str(off.get("unlock_if", "")))
                if m:
                    gate = float(m.group(1))
                eff_d = max(self._npc_depth(vid), gate)
                if min_d is None or eff_d < min_d:
                    min_d = eff_d
                price = {k: v for k, v in (off.get("price", {}) or {}).items()}
                self.offers.append({"item": cid, "vendor": vid, "price": price, "depth": eff_d})
                self.vendor_offers[vid] += 1
                self.item_vendors[cid].add(vid)
                for b in price:
                    self.price_use[b] += 1
                    if b in self.blocks:
                        self.item_blocks[cid].add(b)
                        self.consumers[b].add(cid)
                    elif b in self.items:
                        self.item_prereqs[cid].add(b)
                        self.prereq_dependents[b].add(cid)
            self.item_min_depth[cid] = min_d if min_d is not None else 0.0
        for bid, d in self.blocks.items():
            for biome in (d.get("biome_weights") or {}):
                self.consumers[bid].add(biome)
        for bio, d in self.biomes.items():
            for bid in (d.get("biome_weights") or {}):
                if bid in self.blocks:
                    self.consumers[bid].add(bio)

    # ---- modular skill brackets & endgame themes
    def is_skill_or_station_node(self, cid_or_cap: str | dict) -> bool:
        if isinstance(cid_or_cap, dict):
            d = cid_or_cap
        else:
            d = self.items.get(str(cid_or_cap)) or self.caps.get(str(cid_or_cap))
        if not d:
            return False
        tags = set(d.get("tags", []) or [])
        if tags & {"skill_bracket", "craft_skill_mastery", "craft_homestead_station", "craft_achievement_relic"}:
            return True
        if any(str(t).startswith("skill_school_") for t in tags):
            return True
        return "place_in_house" in (d.get("affordances", []) or []) and "craft_homestead_station" in tags

    def bracket_of(self, cid: str) -> int:
        d = self.caps.get(cid, {})
        for t in d.get("tags", []) or []:
            if isinstance(t, str) and re.match(r"^bracket_[1-5]$", t):
                return int(t.split("_")[1])
        z = self.item_min_depth.get(cid, 0.0)
        if z < 250:
            return 1
        if z < 700:
            return 2
        if z < 1400:
            return 3
        if z < 2200:
            return 4
        return 5

    def skill_school_of(self, cid: str) -> str:
        d = self.caps.get(cid, {})
        for t in d.get("tags", []) or []:
            if isinstance(t, str) and t.startswith("skill_school_"):
                return t
        motifs = sorted(self.tok.get(cid, (set(), set()))[0])
        head = motifs[0] if motifs else cid.split("/")[-1].split("_")[0]
        return f"skill_school_{head}"

    def theme_of(self, cid: str) -> str | None:
        d = self.caps.get(cid, {})
        for t in d.get("tags", []) or []:
            if isinstance(t, str) and t.startswith("theme_"):
                return t
        return None

    def skill_bracket_nodes(self, ceiling: float = 99999.0) -> list[dict]:
        out: list[dict] = []
        for cid in sorted(self.items):
            if not self.is_skill_or_station_node(cid):
                continue
            d_unlock = self.item_min_depth.get(cid, 0.0)
            if d_unlock > ceiling:
                continue
            d = self.items[cid]
            tags = d.get("tags", []) or []
            explicit_skill = any(
                isinstance(t, str) and (t in ("skill_bracket", "craft_skill_mastery", "craft_homestead_station") or t.startswith("skill_school_"))
                for t in tags
            )
            deps = sorted(self.prereq_dependents.get(cid, set()))
            out.append({
                "id": cid,
                "name": d.get("meta", {}).get("name", cid),
                "desc": d.get("meta", {}).get("description", ""),
                "bracket": self.bracket_of(cid),
                "school": self.skill_school_of(cid),
                "theme": self.theme_of(cid),
                "unlock_depth": d_unlock,
                "explicit_skill": explicit_skill,
                "dependent_count": len(deps),
                "dependents": deps,
            })
        return out

    def expandable_skill_schools(self, ceiling: float = 99999.0) -> list[dict]:
        by_school: dict[str, list[dict]] = defaultdict(list)
        for node in self.skill_bracket_nodes(ceiling):
            if node["explicit_skill"] or node["dependent_count"] > 0:
                by_school[node["school"]].append(node)
        out: list[dict] = []
        for school, nodes in sorted(by_school.items()):
            nodes.sort(key=lambda x: (x["bracket"], x["unlock_depth"]))
            top = nodes[-1]
            if top["bracket"] < 5:
                out.append({
                    "school": school,
                    "current_bracket": top["bracket"],
                    "next_bracket": top["bracket"] + 1,
                    "prev_capsule_id": top["id"],
                    "prev_name": top["name"],
                    "prev_depth": top["unlock_depth"],
                    "theme": top["theme"],
                })
        return out

    def discovered_themes(self) -> dict[str, dict]:
        themes: dict[str, dict] = {}
        for cid, d in self.caps.items():
            t_tag = self.theme_of(cid)
            if not t_tag:
                continue
            info = themes.setdefault(t_tag, {"members": [], "disciplines": set(), "brackets": set()})
            info["members"].append(cid)
            info["brackets"].add(self.bracket_of(cid))
            for t in d.get("tags", []) or []:
                if isinstance(t, str) and (t.startswith("craft_") or t.startswith("world_")):
                    info["disciplines"].add(t)
        return {
            k: {
                "member_count": len(v["members"]),
                "members": sorted(v["members"])[:12],
                "disciplines": sorted(v["disciplines"]),
                "brackets": sorted(v["brackets"]),
            }
            for k, v in sorted(themes.items())
        }

    # ---- frontier, dynamic brackets, economy & repair queue
    def frontier_depth(self) -> float:
        """Computes the live obtainable block depth frontier F = max(stats.z_unlock)."""
        vals = [
            float(b.raw.get("stats", {}).get("z_unlock", 0.0) or 0.0)
            for b in self.by_ns.get("blocks", [])
            if self.obtainable(b.id)
        ]
        if not vals:
            vals = [
                float(b.raw.get("stats", {}).get("z_unlock", 0.0) or 0.0)
                for b in self.by_ns.get("blocks", [])
            ]
        return max(vals, default=150.0)

    def dynamic_bracket_bands(self) -> Dict[int, Tuple[int, int]]:
        """Derives quantile depth bands (z_lo, z_hi) for Brackets 1..5 scaled to live frontier F."""
        f_val = max(50.0, self.frontier_depth())
        b1_hi = int(min(249.0, f_val))
        b2_lo = int(min(250.0, max(50.0, f_val * 0.6)))
        b2_hi = int(min(699.0, max(float(b2_lo + 60), f_val + 120.0)))
        b3_lo = int(min(700.0, max(120.0, f_val * 1.1)))
        b3_hi = int(min(1399.0, max(float(b3_lo + 120), f_val + 240.0, f_val * 1.8)))
        b4_lo = int(min(1400.0, max(200.0, f_val * 1.6)))
        b4_hi = int(min(2199.0, max(float(b4_lo + 180), f_val + 360.0, f_val * 2.5)))
        b5_lo = int(min(2200.0, max(300.0, f_val * 2.2)))
        b5_hi = int(min(4000.0, max(float(b5_lo + 250), f_val + 500.0, f_val * 3.5)))
        return {
            1: (0, b1_hi),
            2: (b2_lo, b2_hi),
            3: (b3_lo, b3_hi),
            4: (b4_lo, b4_hi),
            5: (b5_lo, b5_hi),
        }

    def open_brackets(self) -> List[int]:
        """Bracket 1 is always open. Bracket k+1 opens iff Bracket k is open and has >= min_offers across >= min_vendors."""
        pacing = _load_json_safe(PACING_FILE, {})
        fg = pacing.get("frontier_growth", {}) if isinstance(pacing.get("frontier_growth"), dict) else {}
        min_offers = int(fg.get("bracket_open_min_offers", 12))
        min_vendors = int(fg.get("bracket_open_min_vendors", 2))

        offers_per_bracket: Dict[int, int] = defaultdict(int)
        vendors_per_bracket: Dict[int, set[str]] = defaultdict(set)
        for o in self.all_offers:
            b = self.bracket_of(o["item"])
            offers_per_bracket[b] += 1
            if o.get("vendor"):
                vendors_per_bracket[b].add(str(o["vendor"]))

        opened = [1]
        for k in range(1, 5):
            if offers_per_bracket[k] >= min_offers and len(vendors_per_bracket[k]) >= min_vendors:
                opened.append(k + 1)
            else:
                break
        return opened

    def recursive_copper_cost(self) -> Dict[str, float]:
        """Computes recursive copper-equivalent cost C(u) for every capsule u over 8 relaxation passes."""
        hb = _load_json_safe(HEALTH_BASELINE_FILE, {})
        evf = hb.get("economy_value_flow", {}) if isinstance(hb.get("economy_value_flow"), dict) else {}
        perm_w = float(evf.get("permanent_prereq_amortization_weight", 0.25))
        cons_w = float(evf.get("consumed_prereq_weight", 1.0))

        costs: Dict[str, float] = {}
        for cid, d in self.caps.items():
            st = d.get("stats", {}) or {}
            bv = float(st.get("base_value", st.get("value_base", 1.0)) or 1.0)
            if cid.startswith("blocks/"):
                zu = float(st.get("z_unlock", 0.0) or 0.0)
                costs[cid] = max(1.0, bv) * (1.0 + zu / 250.0)
            else:
                costs[cid] = max(1.0, bv)

        for _ in range(8):
            for cid, d in self.caps.items():
                if cid.startswith("blocks/"):
                    continue
                offers = d.get("offered_by", []) or []
                offer_costs: list[float] = []
                for o in offers:
                    if not isinstance(o, dict):
                        continue
                    price = o.get("price", {}) or {}
                    if not isinstance(price, dict) or not price:
                        continue
                    c_sum = 0.0
                    for ing, qty in price.items():
                        try:
                            q = float(qty)
                        except (TypeError, ValueError):
                            q = 1.0
                        is_perm = str(ing).startswith("upgrades/") or (
                            ing in self.capsules and self.is_skill_or_station_node(self.capsules[ing])
                        )
                        w = perm_w if is_perm else cons_w
                        c_sum += max(0.0, q) * w * costs.get(str(ing), 1.0)
                    if c_sum > 0.0:
                        offer_costs.append(c_sum)
                if offer_costs:
                    costs[cid] = max(1.0, min(offer_costs))
        return costs

    def capsule_power_score(self, cid: str | dict) -> float:
        """Computes a positive power score from stats.base_dps, modifiers magnitudes, and reactions counts."""
        d = cid if isinstance(cid, dict) else self.caps.get(str(cid), {})
        if not isinstance(d, dict):
            return 10.0
        st = d.get("stats", {}) or {}
        try:
            dps = max(0.0, float(st.get("base_dps", 0.0) or 0.0))
        except (TypeError, ValueError):
            dps = 0.0
        mods = d.get("modifiers", []) or []
        mod_score = 0.0
        for m in mods:
            if not isinstance(m, dict):
                continue
            try:
                v = abs(float(m.get("value", 1.0)))
                mod_score += min(25.0, math.log1p(v) * 4.0)
            except (TypeError, ValueError):
                mod_score += 4.0
        rxs = d.get("reactions", []) or []
        rx_count = sum(len(r.get("do", []) or []) if isinstance(r, dict) else 1 for r in rxs)
        return max(1.0, 10.0 + min(150.0, dps * 0.8) + min(60.0, mod_score) + min(40.0, rx_count * 5.0))

    def health_metrics(self) -> Dict[str, Any]:
        """Returns corpus concentration, value-flow ingredient ratio, frontier depth, and open brackets."""
        total_offers = len(self.all_offers)
        v_counter: Counter = Counter()
        c_counter: Counter = Counter()
        non_block_offers = 0
        for o in self.all_offers:
            vid = o.get("vendor", "")
            if vid:
                v_counter[vid] += 1
            price = o.get("price", {}) or {}
            if any(not str(k).startswith("blocks/") for k in price):
                non_block_offers += 1
            for k in price:
                c_counter[k] += 1

        max_vendor_id, max_vendor_cnt = (v_counter.most_common(1) or [("", 0)])[0]
        total_price_entries = sum(c_counter.values()) or 1
        top3_cnt = sum(n for _, n in c_counter.most_common(3))
        denom = max(1, total_offers)
        return {
            "capsule_count": len(self.caps),
            "total_offers": total_offers,
            "max_vendor_id": max_vendor_id,
            "max_vendor_offer_share": round(max_vendor_cnt / denom, 6),
            "top3_currency_share": round(top3_cnt / total_price_entries, 6),
            "non_block_ingredient_offer_ratio": round(non_block_offers / denom, 6),
            "frontier_depth_z": float(self.frontier_depth()),
            "open_brackets": self.open_brackets(),
        }

    # ---- block & npc helpers (preserving all legacy & alias signatures)
    def z_unlock(self, bid: str) -> float:
        v = self.blocks.get(bid, {}).get("stats", {}).get("z_unlock", 0)
        return float(v) if isinstance(v, (int, float)) else 0.0

    def obtainable(self, bid: str) -> bool:
        d = self.blocks.get(bid)
        if not d:
            return False
        s = d.get("stats", {})
        return "mineable_block" in d.get("affordances", []) and float(s.get("spawn_prob", 0) or 0) > 0

    def is_hazardish(self, bid: str) -> bool:
        return bool(self.tok[bid][1] & {"hazard", "fluid"})

    def consumer_count(self, bid: str) -> int:
        return len(self.consumers.get(bid, set()) - {bid})

    def orphan_blocks(self) -> list[str]:
        return sorted(b for b in self.blocks if b not in STARTER_BLOCKS and self.consumer_count(b) < 2)

    def orphaned_ores(self) -> list[str]:
        """Dead-end or under-linked blocks/* sorted by recipe sink count (price_use) then total consumer count."""
        return sorted(
            (b for b in self.blocks if b not in STARTER_BLOCKS and (self.price_use.get(b, 0) == 0 or self.consumer_count(b) < 2)),
            key=lambda b: (self.price_use.get(b, 0), self.consumer_count(b), b),
        )

    def orphan_npcs(self) -> list[str]:
        return sorted(n for n in self.npcs if self.vendor_offers.get(n, 0) == 0)

    def under_stocked_npcs(self, min_offers: int = 3) -> list[str]:
        """Specialist NPCs with fewer than min_offers (default < 3) offers, ordered by offer count ascending."""
        return sorted(
            (n for n in self.npcs if self.vendor_offers.get(n, 0) < min_offers),
            key=lambda n: (self.vendor_offers.get(n, 0), self._npc_depth(n), n),
        )

    def under_used_biomes(self) -> list[str]:
        return sorted(
            self.biomes,
            key=lambda b: (len(self.biomes[b].get("biome_weights", {}) or {}), b),
        )

    def under_used_catalysts(self) -> list[str]:
        return sorted(
            (c for c, d in self.caps.items() if "catalyst" in (d.get("affordances", []) or [])),
            key=lambda c: (self.price_use.get(c, 0) + len(self.consumers.get(c, set())), c),
        )

    def under_used_currencies(self) -> list[str]:
        return sorted(
            (b for b in self.blocks if b not in STARTER_BLOCKS and self.obtainable(b)),
            key=lambda b: (self.price_use.get(b, 0), self.consumer_count(b), b),
        )

    def deterministic_repair_queue(self, limit: int = 8) -> List[Dict[str, Any]]:
        """Returns a prioritized list of actionable repair dicts covering orphan ores, under-stocked NPCs,
        un-advanced skill schools, and frontier advancement."""
        queue: List[Dict[str, Any]] = []

        # Priority 1: Dead-end blocks/* with 0 recipe sinks (or < 2 consumers)
        for bid in self.orphaned_ores():
            sinks = self.price_use.get(bid, 0)
            zu = int(self.z_unlock(bid))
            queue.append({
                "kind": "orphan_ore",
                "target_id": bid,
                "priority": 1,
                "directive": (
                    f"Use orphan stratum `{bid}` (`z_unlock={zu}`, recipe sinks={sinks}) in `offered_by[0].price` "
                    f"and/or a block-specific modifier/reaction so it has an active crafting sink."
                ),
            })

        # Priority 2: npcs/* vendors with < 3 offers
        for nid in self.under_stocked_npcs(min_offers=3):
            cnt = self.vendor_offers.get(nid, 0)
            ud = int(self._npc_depth(nid))
            queue.append({
                "kind": "under_stocked_npc",
                "target_id": nid,
                "priority": 2,
                "directive": (
                    f"Assign specialist vendor `{nid}` (`unlock_depth={ud}`, current offers={cnt}) as "
                    f"`offered_by[0].vendor` to decentralize offers away from `npcs/peddler_vayne`."
                ),
            })

        # Priority 3: skill_school_* chains stuck at bracket_1 with < 2 dependent recipes
        for node in self.skill_bracket_nodes():
            if node["explicit_skill"] and node["bracket"] == 1 and node["dependent_count"] < 2:
                queue.append({
                    "kind": "under_used_skill_school",
                    "target_id": node["id"],
                    "priority": 3,
                    "directive": (
                        f"Gate your recipe on `{node['id']}` (`{node['school']}`, `bracket_1`, dependents={node['dependent_count']}) "
                        f"by including `\"{node['id']}\": 1` (non-consumed prerequisite) in `offered_by[0].price`."
                    ),
                })

        # Priority 4: Frontier advancement needed when frontier_depth() < 2200
        f_depth = self.frontier_depth()
        if f_depth < 2200.0:
            f_int = int(f_depth)
            queue.append({
                "kind": "advance_frontier",
                "target_id": f"frontier_z_{f_int}",
                "priority": 4,
                "directive": (
                    f"Quarry depth frontier is currently `F = {f_int}m` (open brackets: `{self.open_brackets()}`). "
                    f"Anchor deep strata or advance next-step blocks inside `[{f_int + 40}, {f_int + 120}]`."
                ),
            })

        return queue[: max(1, limit)]

    @staticmethod
    def parse_steward_footer(text: str) -> Optional[Dict[str, Any]]:
        return parse_steward_footer(text)

    def vendor_share(self) -> tuple[str, float]:
        total = sum(self.vendor_offers.values()) or 1
        top, n = (self.vendor_offers.most_common(1) or [("", 0)])[0]
        return top, n / total

    # ---- logic
    def pair_affinity(self, a: str, b: str, tool_fit: bool = False) -> int:
        (ma, ca), (mb, cb) = self.tok[a], self.tok[b]
        return affinity(ma, ca, mb, cb, tool_fit)

    def item_affinity(self, item: str) -> int:
        d = self.items[item]
        tt = d.get("stats", {}).get("tool_type")
        best = 0
        vendors = self.item_vendors.get(item, set())
        for v in vendors:
            if v in self.npcs:
                best = max(best, self.pair_affinity(item, v))
        for b in self.item_blocks.get(item, set()):
            fit = bool(tt) and tt == self.blocks[b].get("stats", {}).get("ideal_tool")
            best = max(best, self.pair_affinity(item, b, fit))
            for v in vendors:
                if v in self.npcs:
                    best = max(best, self.pair_affinity(v, b))
        for p_item in self.item_prereqs.get(item, set()):
            if p_item in self.items:
                best = max(best, self.pair_affinity(item, p_item))
        return best

    # ---- anchor selection for briefs
    def vendor_candidates(self, ceiling: float, claimed: set[str], dominant_cap: float = 0.40) -> dict[str, float]:
        top, share = self.vendor_share()
        out: dict[str, float] = {}
        for nid in self.npcs:
            if self._npc_depth(nid) > ceiling:
                continue
            if nid == top and share > dominant_cap:
                continue
            n = self.vendor_offers.get(nid, 0) + (3 if nid in claimed else 0)
            out[nid] = 1.0 / (1.0 + n) ** 2
        return out

    def block_candidates(self, ceiling: float, claimed: set[str], hazard: bool = False) -> dict[str, float]:
        out: dict[str, float] = {}
        for bid in self.blocks:
            if not self.obtainable(bid) or self.z_unlock(bid) > ceiling:
                continue
            if self.is_hazardish(bid) != hazard:
                continue
            n = self.consumer_count(bid) + (3 if bid in claimed else 0)
            out[bid] = 1.0 / (1.0 + n) ** 2
        return out

    def pick_pair(self, rng, tier: str, ceiling: float, claimed: set[str], hazard: bool = False):
        """Pick (vendor, block, affinity, tier_used) from the requested logic band, degrading gracefully."""
        vs = self.vendor_candidates(ceiling, claimed)
        bs = self.block_candidates(ceiling, claimed, hazard)
        if not vs or not bs:
            return None
        pairs = [(v, b, self.pair_affinity(v, b), vw * bw) for v, vw in vs.items() for b, bw in bs.items()]
        chain = {"canonical": ["canonical", "plausible", "loose"], "plausible": ["plausible", "canonical", "loose"],
                 "whimsical": ["loose", "plausible"], "absurd": ["loose", "plausible"]}[tier]
        for band in chain:
            pool = [p for p in pairs if tier_of(p[2]) == band]
            if pool:
                v, b, a, _ = rng.choices(pool, weights=[p[3] for p in pool], k=1)[0]
                used = band if band != "loose" else tier
                return v, b, a, used
        return None

    # ---- scorecard & markdown digest
    def scorecard(self, recent: int = 30) -> dict:
        unobt, ahead = [], []
        for o in self.offers:
            for b in o["price"]:
                if b in self.blocks:
                    if not self.obtainable(b):
                        unobt.append([o["item"], b, "not mineable"])
                    elif self.z_unlock(b) > o["depth"] + AHEAD_SLACK:
                        ahead.append([o["item"], b, f"z_unlock {self.z_unlock(b):.0f} vs offer depth {o['depth']:.0f}"])
                elif b in self.items:
                    req_d = self.item_min_depth.get(b, 0.0)
                    if req_d > o["depth"] + AHEAD_SLACK:
                        ahead.append([o["item"], b, f"prereq depth {req_d:.0f} vs offer depth {o['depth']:.0f}"])
                else:
                    unobt.append([o["item"], b, "dangling"])
        prices = Counter(b for o in self.offers for b in o["price"])
        total_p = sum(prices.values()) or 1
        top3 = prices.most_common(3)
        # connectivity (union-find over functional edges)
        parent: dict[str, str] = {c: c for c in self.caps}

        def find(x: str) -> str:
            while parent[x] != x:
                parent[x] = parent[parent[x]]
                x = parent[x]
            return x

        edges = 0
        for cid, vs in self.item_vendors.items():
            for v in vs:
                if v in parent:
                    parent[find(cid)] = find(v)
                    edges += 1
        for cid, bs in self.item_blocks.items():
            for b in bs:
                parent[find(cid)] = find(b)
                edges += 1
        for cid, ps in self.item_prereqs.items():
            for p_item in ps:
                if p_item in parent:
                    parent[find(cid)] = find(p_item)
                    edges += 1
        for bid, cons in self.consumers.items():
            for c in cons:
                if c in parent and c.startswith("biomes/"):
                    parent[find(bid)] = find(c)
                    edges += 1
        comp = Counter(find(c) for c in self.caps)
        derived = Counter(tier_of(self.item_affinity(i)) for i in self.items)
        declared = Counter((declared_tier(d) or "untagged") for d in self.items.values())
        rec_ids = recent_ids(recent)
        rec_decl = Counter((declared_tier(self.caps[i]) or "untagged") for i in rec_ids if i in self.items)
        top_v, share_v = self.vendor_share()
        skill_nodes = self.skill_bracket_nodes()
        explicit_skills = [s for s in skill_nodes if s["explicit_skill"]]
        underused_skills = [s["id"] for s in explicit_skills if s["dependent_count"] < 2]
        themes = self.discovered_themes()
        f_depth = float(self.frontier_depth())
        open_b = self.open_brackets()
        return {
            "capsules": len(self.caps), "items": len(self.items), "blocks": len(self.blocks),
            "npcs": len(self.npcs), "biomes": len(self.biomes),
            "frontier_depth_z": f_depth,
            "open_brackets": open_b,
            "dynamic_bracket_bands": {f"bracket_{k}": list(v) for k, v in self.dynamic_bracket_bands().items()},
            "orphan_blocks": self.orphan_blocks(), "orphan_npcs": self.orphan_npcs(),
            "skill_brackets": {
                "total_nodes": len(skill_nodes),
                "explicit_skill_brackets": len(explicit_skills),
                "under_assigned_skills": underused_skills[:12],
                "expandable_schools": self.expandable_skill_schools()[:8],
            },
            "themes": themes,
            "vendor_concentration": {"top": top_v, "share": round(share_v, 3)},
            "currency_concentration": {"top3": [k for k, _ in top3], "share": round(sum(n for _, n in top3) / total_p, 3)},
            "health_metrics": self.health_metrics(),
            "repair_queue": self.deterministic_repair_queue(limit=8),
            "unobtainable_prices": unobt, "ahead_of_curve_prices": ahead,
            "connectivity": {"largest_component_share": round(comp.most_common(1)[0][1] / max(len(self.caps), 1), 3),
                             "mean_degree": round(2 * edges / max(len(self.caps), 1), 2)},
            "logic": {"derived": dict(derived), "declared": dict(declared),
                      "recent_n": len(rec_ids), "recent_declared": dict(rec_decl)},
        }

    def render_markdown_digest(self, recent: int = 30) -> str:
        sc = self.scorecard(recent)
        sb = sc["skill_brackets"]
        vc, cc = sc["vendor_concentration"], sc["currency_concentration"]
        lines = [
            f"# Content Graph Digest ({sc['capsules']} capsules)",
            f"- **Counts**: items={sc['items']}, blocks={sc['blocks']}, npcs={sc['npcs']}, biomes={sc['biomes']}",
            f"- **Frontier Depth (`frontier_depth_z`)**: `{sc['frontier_depth_z']:.1f}m`",
            f"- **Open Brackets (`open_brackets`)**: `{sc['open_brackets']}`",
            f"- **Dynamic Bracket Bands**: `{sc['dynamic_bracket_bands']}`",
            f"- **Orphan Blocks ({len(sc['orphan_blocks'])})**: {', '.join(sc['orphan_blocks']) or '-'}",
            f"- **Orphan NPCs ({len(sc['orphan_npcs'])})**: {', '.join(sc['orphan_npcs']) or '-'}",
            f"- **Skill Nodes**: {sb['total_nodes']} total ({sb['explicit_skill_brackets']} explicit), under-assigned={len(sb['under_assigned_skills'])}",
            f"- **Vendor Concentration**: `{vc['top']}` holds `{vc['share']:.1%}` of offers",
            f"- **Currency Concentration**: top3 `{cc['top3']}` = `{cc['share']:.1%}` of price entries",
        ]
        rq = sc.get("repair_queue", [])
        if rq:
            lines.append("- **Top Repair Queue Targets**:")
            for item in rq[:5]:
                lines.append(f"  - [P{item['priority']} `{item['kind']}` -> `{item['target_id']}`] {item['directive']}")
        return "\n".join(lines)


ContentGraph = Graph


def build() -> Graph:
    return Graph(load_capsules())


def recent_share(g: Graph, tier: str, n: int = 30) -> float:
    ids = [i for i in recent_ids(n) if i in g.items]
    return (sum(1 for i in ids if declared_tier(g.caps[i]) == tier) / len(ids)) if ids else 0.0


def main() -> int:
    ap = argparse.ArgumentParser(description="Print the content synergy scorecard (read-only).")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--recent", type=int, default=30)
    args = ap.parse_args()
    sc = build().scorecard(args.recent)
    if args.json:
        print(json.dumps(sc, indent=1, sort_keys=True))
        return 0
    print(f"CAPSULES {sc['capsules']}  items={sc['items']} blocks={sc['blocks']} npcs={sc['npcs']} biomes={sc['biomes']}")
    print(f"frontier depth: {sc['frontier_depth_z']:.1f}m   open brackets: {sc['open_brackets']}   bands: {sc['dynamic_bracket_bands']}")
    print(f"orphan blocks ({len(sc['orphan_blocks'])}): {', '.join(sc['orphan_blocks']) or '-'}")
    print(f"orphan npcs   ({len(sc['orphan_npcs'])}): {', '.join(sc['orphan_npcs']) or '-'}")
    sb = sc["skill_brackets"]
    print(f"skill nodes   ({sb['total_nodes']} total, {sb['explicit_skill_brackets']} explicit): under-assigned={len(sb['under_assigned_skills'])} expandable_schools={len(sb['expandable_schools'])}")
    vc, cc = sc["vendor_concentration"], sc["currency_concentration"]
    print(f"vendor concentration: {vc['top']} holds {vc['share']:.1%} of offers")
    print(f"currency concentration: top3 {cc['top3']} = {cc['share']:.1%} of price entries")
    print(f"unobtainable priced blocks: {len(sc['unobtainable_prices'])}   ahead-of-curve prices: {len(sc['ahead_of_curve_prices'])}")
    print(f"connectivity: largest component {sc['connectivity']['largest_component_share']:.1%}, mean degree {sc['connectivity']['mean_degree']}")
    lg = sc["logic"]
    print(f"logic (derived from graph, all items): {lg['derived']}")
    print(f"logic (declared tags, all items): {lg['declared']}   recent {lg['recent_n']}: {lg['recent_declared']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
