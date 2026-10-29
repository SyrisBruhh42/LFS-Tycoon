#!/usr/bin/env python3
"""Gate G0: Scaffolds a valid new capsule folder from an archetype."""
import argparse
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent.parent
CAPSULES_DIR = ROOT / "content" / "capsules"

ARCHETYPES = {
    "tool": {
        "affordances": ["carry", "equip_tool", "sell"],
        "tags": ["tool", "pickaxe"],
        "stats": {
            "tool_type": "PICKAXE",
            "tool_tier": 0,
            "base_dps": 12.0,
            "durability_max": 300.0,
            "is_rechargeable": 1,
            "base_value": 25.0,
        },
        "vars": {"durability_left": 300.0},
        "modifiers": [],
        "reactions": [],
        "offline": "coarse",
    },
    "textile": {
        "affordances": ["carry", "place_on_tile", "sell"],
        "tags": ["textile", "tile_cover", "dampener"],
        "stats": {"base_value": 30.0, "dampen_pct": 0.5, "wear_max": 25.0},
        "vars": {"wear": 0.0},
        "modifiers": [
            {
                "stat": "incoming_damage",
                "phase": "mul",
                "if": "tile.covered_by_self and ctx.is_direct_tap == 0",
                "value": "1.0 - self.stats.dampen_pct",
            }
        ],
        "reactions": [
            {
                "on": "on_damage_absorbed",
                "if": "tile.covered_by_self",
                "do": [
                    {"act": "var_add", "var": "self.wear", "by": "1.0"},
                    {"act": "destroy_self", "if": "self.wear >= self.stats.wear_max"},
                ],
            }
        ],
        "offline": "exact",
    },
    "book": {
        "affordances": ["carry", "read_book", "sell"],
        "tags": ["book", "skill_book"],
        "stats": {"base_value": 50.0, "bonus_val": 0.05},
        "vars": {"is_learned": 0.0},
        "modifiers": [],
        "reactions": [
            {
                "on": "on_consume",
                "if": "self.is_learned == 0.0",
                "do": [{"act": "var_set", "var": "self.is_learned", "value": "1.0"}],
            }
        ],
        "offline": "none",
    },
    "consumable": {
        "affordances": ["carry", "consume", "sell"],
        "tags": ["consumable", "food"],
        "stats": {"base_value": 15.0, "duration_sec": 300.0, "speed_mult": 1.25},
        "vars": {"active_sec_left": 0.0},
        "modifiers": [
            {
                "stat": "base_dps",
                "phase": "mul",
                "if": "self.active_sec_left > 0.0",
                "value": "self.stats.speed_mult",
            }
        ],
        "reactions": [
            {
                "on": "on_consume",
                "do": [
                    {
                        "act": "var_set",
                        "var": "self.active_sec_left",
                        "value": "self.stats.duration_sec",
                    }
                ],
            },
            {
                "on": "on_second_tick",
                "if": "self.active_sec_left > 0.0",
                "do": [
                    {
                        "act": "var_add",
                        "var": "self.active_sec_left",
                        "by": "-1.0",
                    },
                    {
                        "act": "destroy_self",
                        "if": "self.active_sec_left <= 0.0",
                    },
                ],
            },
        ],
        "offline": "none",
    },
    "device": {
        "affordances": ["carry", "socket_in_tool", "place_on_tile", "sell"],
        "tags": ["device", "gadget"],
        "stats": {"base_value": 45.0},
        "vars": {"activations": 0.0},
        "modifiers": [],
        "reactions": [],
        "offline": "exact",
    },
    "upgrade": {
        "affordances": ["carry", "read_book", "sell"],
        "tags": ["upgrade", "qol"],
        "stats": {"base_value": 60.0},
        "vars": {"installed": 0.0},
        "modifiers": [],
        "reactions": [],
        "offline": "none",
    },
    "block": {
        "affordances": ["mineable_block", "carry", "sell"],
        "tags": ["block", "ore"],
        "stats": {
            "base_hp": 25.0,
            "base_value": 8.0,
            "ideal_tool": "PICKAXE",
            "strict_tool_lock": 0,
            "z_unlock": 0,
            "l_step": 1000,
            "spawn_prob": 0.05,
            "clump_xy": 6.0,
            "pipe_z": 6.0,
            "priority_rank": 50,
        },
        "vars": {},
        "modifiers": [],
        "reactions": [],
        "offline": "none",
    },
    "biome": {
        "affordances": ["biome_profile"],
        "tags": ["biome"],
        "stats": {"z_min": 0, "z_max": 1000, "weight": 0.25},
        "biome_weights": {"blocks/stone": 1.0, "blocks/dirt": 1.0},
        "vars": {},
        "modifiers": [],
        "reactions": [],
        "offline": "none",
    },
    "npc": {
        "affordances": ["npc_vendor"],
        "tags": ["npc", "vendor"],
        "stats": {"cleanliness_required": 0.0, "saturation_half_volume": 1000.0},
        "vars": {},
        "modifiers": [],
        "reactions": [],
        "offline": "none",
    },
}


def main() -> int:
    parser = argparse.ArgumentParser(description="Scaffold a new StrataPaper capsule.")
    parser.add_argument("--id", required=True, help="Capsule ID in <namespace>/<slug> format")
    parser.add_argument("--archetype", required=True, choices=sorted(ARCHETYPES.keys()))
    parser.add_argument("--name", required=True, help="Human-readable display name")
    parser.add_argument("--author", default="jules:session", help="Author tag")
    args = parser.parse_args()

    parts = args.id.strip("/").split("/")
    if len(parts) != 2 or not all(p.replace("_", "").isalnum() and p.islower() for p in parts):
        print(f"ERROR: --id '{args.id}' must be lowercase '<namespace>/<slug>' (alphanumeric + underscores).", file=sys.stderr)
        return 1

    target_dir = CAPSULES_DIR / parts[0] / parts[1]
    target_file = target_dir / "capsule.json"
    if target_file.exists():
        print(f"ERROR: Capsule already exists at {target_file}", file=sys.stderr)
        return 1

    template = json.loads(json.dumps(ARCHETYPES[args.archetype]))
    payload = {
        "schema": 1,
        "meta": {
            "name": args.name,
            "description": f"{args.name} ({args.archetype} capsule).",
            "author": args.author,
            "rarity": "common",
        },
        **template,
    }
    target_dir.mkdir(parents=True, exist_ok=True)
    target_file.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(f"OK: Created {target_file.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
