# JULES CAPSULE CONTRACT (`RFC-0001`)
**Project**: LFS-Tycoon (Codename: *StrataPaper*)  
**Purpose**: Frictionless, zero-conflict creation of deep FTB/Tinkers'-style items, tools, books, textiles, gadgets, foods, and hazards across 300 daily AI sessions.

---

## 1. Core Philosophy: Medium Never Restricts Behavior

In *StrataPaper*, there is no hardcoded class difference between a **Pickaxe**, a **Skill Book**, a **Wool Carpet**, a **Cooked Steak**, an **Enchanted Bell**, or a **Hired Laborer**.
Every object is a **Capsule** (`content/capsules/<namespace>/<slug>/capsule.json`) defined by:
1. **`affordances`** (*How the player interacts with it*: `equip_tool`, `place_on_tile`, `read_book`, `consume`, `place_in_house`, `socket_in_tool`, `sell`, `backfill_material`, `catalyst`).
2. **`tags`** (Semantic descriptors queried by rules, e.g., `["tool", "pickaxe", "clockwork", "disposable"]`).
3. **`stats`** & **`vars`** (Initial numerical parameters and local state registers like `charges_left`, `wear`, `heat`).
4. **`modifiers`** (Declarative stat changes with `phase`: `"base" | "add" | "mul" | "clamp"` and an optional `"if"` condition string).
5. **`reactions`** (Event-driven `WHEN / IF / DO` hooks that fire atomic actions when game events occur).
6. **`offline`** (`"coarse"` for deterministic column lookahead on auto-tools, `"exact"` for discrete-event replay when stateful reactions matter offline, or `"none"`).

---

## 2. Canonical `capsule.json` Schema

```json
{
  "schema": 1,
  "meta": {
    "name": "Thick Wool Dampening Carpet",
    "description": "Laid over a quarry square to absorb 85% of non-direct impact damage (cleave, explosions, or stray drunk taps) before fraying after 40 hits.",
    "author": "jules:example",
    "rarity": "uncommon"
  },
  "affordances": ["carry", "place_on_tile", "sell"],
  "tags": ["textile", "tile_cover", "dampener", "wool"],
  "stats": {
    "base_value": 40.0,
    "dampen_pct": 0.85,
    "wear_max": 40.0
  },
  "vars": {
    "wear": 0.0
  },
  "modifiers": [
    {
      "stat": "incoming_damage",
      "phase": "mul",
      "if": "tile.covered_by_self and ctx.is_direct_tap == 0",
      "value": "1.0 - self.stats.dampen_pct"
    }
  ],
  "reactions": [
    {
      "on": "on_damage_absorbed",
      "if": "tile.covered_by_self",
      "do": [
        {"act": "var_add", "var": "self.wear", "by": "1.0"},
        {"act": "destroy_self", "if": "self.wear >= self.stats.wear_max"}
      ]
    }
  ],
  "offered_by": [
    {
      "vendor": "npcs/peddler_vayne",
      "price": {"blocks/copper": 25},
      "unlock_if": "player.max_depth >= 20"
    }
  ],
  "offline": "exact"
}
```

---

## 3. Allowed Vocabulary Reference

Always check `vocab/*.json` for the authoritative machine-readable definitions.

### 3.1 Canonical Events (`reactions[].on` — `vocab/events.json`)
* **Mining & Grid**:
  * `on_tap`: Player initiates a tap on a tile.
  * `on_hold_tick`: Continuous mining tick (manual finger hold or stationed auto-tool).
  * `on_damage_calc`: Before damage is applied to a tile.
  * `on_damage_dealt`: After positive damage is applied to a tile.
  * `on_damage_absorbed`: When a modifier reduces incoming damage on a tile.
  * `on_overkill`: When damage dealt exceeds remaining block HP before the $50\text{ ms}$ refresh gate clamps it.
  * `on_zero_damage_stall`: When a tool swings at a strict-locked block (`is_strict_tool_locked`, e.g., Water or Obsidian) and deals $0$ damage.
  * `on_block_break`: When `tile.damage_accum >= tile.max_hp` and the block breaks.
  * `on_layer_reveal`: When `z` increments to `z + 1` after the $50\text{ ms}$ refresh gate.
  * `on_backfill`: When a player places backfill dirt/stone (`depth -= 1`).
* **World Physics**:
  * `on_fluid_flow`: When Water or Lava siphons downhill into a deeper orthogonal neighbor.
  * `on_fluid_contact`: When Water contacts Lava (Obsidian formation).
  * `on_hazard_expose`: When a Connected-Component Hazard block is revealed.
  * `on_hazard_detonate`: When a surrounded Hazard cluster detonates via equal-depth Catalysts.
* **Lifecycle & Hub**:
  * `on_second_tick`: Fired once per second of active/simulated time.
  * `on_equip` / `on_unequip`: When an item is equipped or removed.
  * `on_consume`: When a food, drink, or ephemeral book/scroll is consumed.
  * `on_deplete`: When a tool's `charge_seconds_left` or `durability_current` reaches $0$.
  * `on_enter_house` / `on_sleep` / `on_wash` / `on_market_sell`.

### 3.2 Canonical Actions (`reactions[].do[].act` — `vocab/actions.json`)
* `deal_damage`: `{"act": "deal_damage", "target": "<selector>", "amount": "<expr>"}`
  * Valid `target` selectors: `"self_tile"`, `"neighbors_4"`, `"neighbors_8"`, `"random_neighbor_4"`, `"random_neighbor_8"`, `"shallowest_neighbor_4"`, `"shallowest_neighbor_8"`, `"row"`, `"column"`.
  * *Safety Law L8:* Damage dealt by `deal_damage` is flagged as secondary (`ctx.is_secondary_damage == 1`) and cannot re-trigger `on_damage_dealt` or `on_overkill` beyond cascade depth 4.
* `var_set` / `var_add`: `{"act": "var_add", "var": "self.heat", "by": "2.5"}` (or `"shared.<name>"` if declared in `vocab/shared_vars.json`).
* `spawn_item`: `{"act": "spawn_item", "item": "blocks/copper", "tier": "tile.tier", "qty": "1", "route": "backpack|paired_chest"}`
* `consume_item`: `{"act": "consume_item", "item": "blocks/dirt", "qty": "1"}`
* `transform_tile`: `{"act": "transform_tile", "target": "self_tile", "block": "blocks/obsidian_hazard"}`
* `modify_depth`: `{"act": "modify_depth", "target": "self_tile", "delta": "-1"}`
* `modify_fluid`: `{"act": "modify_fluid", "target": "self_tile", "fluid_type": "WATER|LAVA|NONE", "delta_level": "-1"}`
* `emit_alert`: `{"act": "emit_alert", "channel": "house_bell|hud_chime| chest_flag", "tag": "stall_water"}`
* `set_ui_flag`: `{"act": "set_ui_flag", "flag": "hud_chalk_lines|hud_chess_grid|hud_target_loupe|hud_depth_calipers|hud_durability_bars", "enabled": true}`
* `stall_tool`: `{"act": "stall_tool", "pause_battery": true, "pause_durability": true}`
* `destroy_self`: `{"act": "destroy_self"}`
* `transmute_self`: `{"act": "transmute_self", "into": "<namespace>/<slug>"}`

### 3.3 Modifiable Stats & Phase Directionality (`modifiers[]` — `vocab/affordances.json`)
* **Modifier Phases** (evaluated in deterministic order):
  1. `"base"`: Overrides the starting base value (highest-value `"base"` wins).
  2. `"add"`: Added to the base value (`(base + sum(add))`).
  3. `"mul"`: Multiplies the running total (`* prod(mul)`). Use `0.75` for a 25% reduction, `1.25` for a 25% boost. Never use negative multipliers.
  4. `"floor"`: Lower bound (`max(val, floor)`).
  5. `"clamp"`: Upper ceiling (`min(val, clamp)`).
* **Modifiable Stat Reference**:
  * `base_dps` (default tool DPS): Higher = faster mining. Boost with `"add"` (`> 0`) or `"mul"` (`> 1.0`).
  * `incoming_damage` (damage dealt **to the tile**):
    * **Higher (`"mul" > 1.0`)** = block takes MORE damage (shatters faster).
    * **Lower (`"mul" < 1.0`)** = block takes LESS damage (protective dampening, e.g., carpets absorbing splash when `ctx.is_secondary_damage == 1`).
  * `break_time_mult` (default `1.0`): Multiplier on effective mining speed (`eff_dps / break_time_mult`). **Lower (`"mul" < 1.0`)** = faster breaks; **Higher (`"mul" > 1.0`)** = slower breaks.
  * `wrong_tool_penalty` (default penalty when tool class mismatches block): **Lower (`"mul" < 1.0`)** = reduces off-class penalty.
  * `cleave_pct` (default `0.0`): Fraction (`0.0..1.0`) of direct damage splashed to neighbors on hit.
  * `cleave_radius` (default `1.0`): `1` = 4-neighbors (`neighbors_4`), `>= 2` = 8-neighbors (`neighbors_8`).
  * `yield_mult` (default `1.0`): Scales virgin ore drop count (`1.25` = 1 guaranteed + 25% chance of a 2nd drop). **Never set `<= 0`** unless paired with a non-dirt `spawn_item` reaction.
  * `luck_mult` (default `1.0`): `luck_mult - 1.0` is the probability (`0.0..1.0`) that a mined virgin block drops at `tier + 1`.
  * `drunk_drift_px` (default `0.0`): Touch drift amplitude in pixels. **Lower (`"mul" < 1.0` or `"clamp"`)** = steadies aim; **Higher (`"add" > 0`)** = wobblier aim.
  * `battery_drain_mult` (default `1.0`): Rate at which `charge_left` drains. **Lower (`"mul" < 1.0`)** = battery lasts longer.
  * `durability_drain_mult` (default `1.0`): Rate at which `durability_left` drains per swing. **Lower (`"mul" < 1.0`)** = tool wears slower.
  * `min_hp_clamp` (default `0.0`): Minimum HP floor left on a tile (`> 0` prevents a hit or splash from finishing off the block).
  * `chest_route_pct` (default `0.0`): Probability (`0.0..1.0`) that hand-mined virgin drops route directly to `paired_chest` instead of `backpack`.
  * `market_value_mult` (default `1.0`): Multiplier on gold earned when selling items (`> 1.0` = higher sale payout).
  * `grime_gain_mult` (default `1.0`): Multiplier on grime accumulated per broken block (`< 1.0` = stay cleaner longer).
  * `cat_lure_bonus` (default `0.0`): Additive bonus (`0.01..0.05`) to the Lost Cat emergent spawn roll on virgin layer reveal.
  * `vendor_depth_discount` (default `0.0`): Reduces the `unlock_depth` required to access NPC vendors.

### 3.4 Allowed Expression Functions & Variables (Law L4 & L7)
* **Allowed Functions**: `min(a,b)`, `max(a,b)`, `clamp(x,lo,hi)`, `abs(x)`, `floor(x)`, `ceil(x)`, `round(x)`, `sqrt(x)`, `pow(a,b)`, `sin(x)`, `cos(x)`, `lerp(a,b,t)`, `roll(prob)`.
* **Forbidden**: `randf()`, `randi()`, `OS`, `Engine`, `FileAccess`, `DirAccess`, `ClassDB`, any `__` attribute.
* **Allowed Context Scopes**:
  * `self.stats.<key>` (read-only static stat from `stats` block)
  * `self.<var>` (read/write private instance register from `vars` block)
  * `tile.depth`, `tile.max_depth_reached`, `tile.tier`, `tile.hp`, `tile.max_hp`, `tile.fluid_level`, `tile.is_hazard`, `tile.is_strict_locked`, `tile.covered_by_self`
  * `player.max_depth`, `player.grime`, `player.is_rested`, `player.drunk_seconds`
  * `tool.tier`, `tool.dps`, `tool.charge_left`, `tool.durability_left`, `tool.overkill_damage`
  * `ctx.dt`, `ctx.now`, `ctx.is_direct_tap`, `ctx.is_secondary_damage`
  * `shared.<key>` (only for keys registered in `vocab/shared_vars.json`)

---

## 4. Key Physics Invariants & Verification Checklist
1. **Fluid Strict-Lock**: While `tile.fluid_level > 0`, non-`BUCKET` tools deal `0` damage and trigger `on_zero_damage_stall`. Solid blocks never fire `on_block_break` while flooded.
2. **Backward Edges Only**: Items declare `offered_by` pointing to `npcs/*`. Never put `offered_by` inside `npcs/*`, `biomes/*`, or natural `blocks/*`.
3. **Run `python3 tools/preflight.py`** before submitting and ensure it prints `PREFLIGHT OK: submit now.`

