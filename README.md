# LFS-Tycoon (Codename: *StrataPaper*)

**2D Top-Down Layered 3D Quarry & Deep Systemic Incremental RPG**  
**Target Engine**: Godot 4.3 (`gl_compatibility` / Mobile)  
**Primary Benchmark Target**: Google Pixel 8 Pro ($1344 \times 2992$ @ $489\text{ PPI}$, $k=3$, $14 \times 31$ Quarry Sheet) + Linux Multi-Window Desktop Calibration Suite

---

## Architectural Highlights (Milestone 0 / Ground Zero)

1. **The "Stacked Sheets of Paper" Depth Buffer (`engine/grid_manager.gd`)**:
   * Represents an infinite 3D quarry ($z \in [0, \infty)$) in a flat $C \times R$ Structure-of-Arrays (SoA) buffer with $100\%$ persistent block damage (`damage_accum`), a $50\text{ ms}$ zero-spillover `STATE_REFRESH_GATE`, frozen per-save quarry dimensions with smooth viewport panning (**D1**), backfill high-water mark protection (`max_depth_reached`), event-driven downhill cellular fluids, and BFS connected-component hazards.
2. **Exact 3D Vein & Biome Generator (`engine/generator_3d.gd`)**:
   * Uses 3D coherent noise normalized through a baked **Empirical Quantile Lookup Table (LUT)** ($262,144+$ samples) and **Conditional Priority Scaling** so Linux Calibration Sliders achieve $\le 2\%$ relative error even on $0.5\%$ rare ores (**Spike S5**).
   * Supports infinite 2-tuple `(base_id, tier)` depth escalation and composable `BiomeDef` vertical strata lenses.
3. **Antifragile "Jules-300" Drop-In Capsule Engine (`engine/catalog_db.gd`, `engine/rule_engine.gd`)**:
   * Zero central registry files: every block, tool, skill book, wool carpet, bell, food, upgrade, biome, and NPC lives in an isolated `content/capsules/<namespace>/<slug>/capsule.json` folder (**0% Git merge conflicts across 60–300 daily Jules sessions**).
   * Medium never restricts behavior: items compose `affordances`, `modifiers` (`base/add/mul/clamp`), and `reactions` (`WHEN / IF / DO`) with per-capsule circuit breakers and quarantine isolation (**Spikes S2 & S4**).
4. **3-Mode Offline Simulator (`engine/offline_sim.gd`)**:
   * Supports per-capsule `offline: "coarse" | "exact" | "none"` (**D2 & Spike S1**), allowing a 4-hour Wind-Up Pick to look ahead down its deterministic 3D column and halt accurately on subterranean water or hazards in microseconds.

---

## Validation & Test Commands

* **Static Lint, AST Allow-List & Economy Cycle Check (Gate G1 — Zero-Install Python)**:
  ```bash
  python3 tools/check_capsules.py --strict
  ```
* **Headless Godot 4.3 Engine & Spikes S1–S5 Verification (Gate G2)**:
  ```bash
  godot --headless --path . --import --quit
  godot --headless --path . -s tests/run_all_spikes.gd
  ```

## LFS Suite `v1.1.0` Capsule Alignment (`3-lfs-aegis-linux/capsules/lfs-tycoon`, `PF-07`, `lfs-local-abac-v1`)

StrataPaper (`LFS-Tycoon`, `PF-07`) is integrated into `3-lfs-aegis-linux/capsules/lfs-tycoon` with `lfs-local-abac-v1` offline policy alignment under the [LFS Ecosystem Plug-In & Synergy Standard](../../../LFS-ECOSYSTEM-PLUGIN-STANDARD.md).

