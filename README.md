<!-- HUMAN-NOTES:BEGIN -->
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

## Capsule Manifest & Runtime Alignment (`PF-07`)

StrataPaper (`LFS-Tycoon`, `PF-07`) ships `capsule.manifest.json` with `lfs-local-abac-v1` offline policy alignment and headless Godot 4.3 capsule verification (`tools/check_capsules.py --strict`).

---

## Legal, Licensing, Credits & Security

* **License**: [`LICENSE`](./LICENSE) — Copyright (c) 2026 SyrisBruhh42. All Rights Reserved.
* **Legal & IP Notice**: [`LEGAL.md`](./LEGAL.md) & [`NOTICE`](./NOTICE) — Intellectual property reservation, warranty disclaimer, and compliance terms.
* **Open-Source & Font Attributions**: [`CREDITS.md`](./CREDITS.md) — Third-party engine, runtime, and SIL Open Font License 1.1 typography credits.
* **Security Policy**: [`SECURITY.md`](./SECURITY.md) — Zero-Trust security invariants and private vulnerability disclosure policy.
<!-- HUMAN-NOTES:END -->

<!-- STEWARD:BEGIN -->
## LFS Oasis Sovereign Steward Manifest (`v2.0.0-cp12-argon4-apex`)

| Property | Value |
| :--- | :--- |
| **Repository** | `SyrisBruhh42/LFS-Tycoon` |
| **Capsule / Project ID** | `lfs-tycoon` (`PF-07`) |
| **Suite Release Alignment** | `LFS Oasis v2.0.0 / CP-12 + v3.8-sovereign-forge` (`v2.0.0-cp12-argon4-apex`) |
| **Runtime & Architecture** | Godot 4.3 (`gl_compatibility` / Mobile & Linux Desktop) + Python 3.12 Capsule Verifier (`tools/check_capsules.py`) |
| **Local Storage Engine** | Local Godot `user://` Save Lab (`aegisEnvelopeV1` AES-256-GCM) & SQLite WAL |
| **Governance & ABAC** | `AUTH-1` Total Typed ABAC (`lfs-local-abac-v1`) · `ZT-6` Zero-Trust Scrubbing |

### 1. Architecture & Four-Umbrella (`U1..U4`) Integration
2D top-down layered 3D quarry and deep systemic incremental RPG featuring a Structure-of-Arrays (SoA) depth buffer (`engine/grid_manager.gd`), Empirical Quantile LUT 3D vein generator (`engine/generator_3d.gd`), drop-in Jules-300 capsule engine (`engine/catalog_db.gd`), and 3-mode deterministic offline simulator.

- **Offline-First Autonomy**: Operates 100% locally by default with deterministic state persistence and zero mandatory cloud dependencies.
- **LFS Oasis Suite Dockability**: Integrates with `2-lfs-server` (`127.0.0.1:3000`), `3-lfs-aegis-linux` (`Willow v0.2.0` / `lfs-ctl` Spine / Local Sovereign Forge `:19447`), and `4-lfs-aegis-android` via `aegisEnvelopeV1` AES-256-GCM Save Lab envelopes and `lds-tokens.w3c.json` theme packs (`evergreen-dark`, `evergreen-light`, `high-contrast`, `calm`).

### 2. Zero-Trust Credential Vault & `RATCHET-11` Secret Hygiene
- **Zero Committed Secrets**: Static configuration files (`firebase-applet-config.json`, `.env.example`) carry `"VAULT_INJECTED_AT_RUNTIME"` placeholders. No literal `AIzaSy*`, `GOCSPX-*`, `ya29.*`, `1//*`, or `sk-*` keys are ever stored in Git history or working trees.
- **Runtime Injection & Offline Fallback**: Client loaders resolve credentials strictly at runtime via `import.meta.env.VITE_FIREBASE_API_KEY` or the loopback Sovereign Vault endpoint (`/api/lfs/vault/client-config`) and automatically fall back to local IndexedDB / SQLite WAL storage when offline.
- **Privacy & Third-Party Disclosures**: See [`PRIVACY.md`](./PRIVACY.md) and [`THIRD_PARTY_NOTICES.md`](./THIRD_PARTY_NOTICES.md).

### 3. Copyright Management Information (`17 U.S.C. § 1202`) & TDM Opt-Out (`EU DSM Art. 4`)
> [!IMPORTANT]
> - `Copyright (c) 2026 SyrisBruhh42 / Lewis Family Systems. All Rights Reserved.`
> - `PROPRIETARY AGENT ARCHITECTURE & SKILL SPECIFICATION: Any unauthorized copying, commercial repackaging as a standalone agent skill (including but not limited to conversion into SKILL.md packages or listing on third-party AI skill marketplaces such as Agensi.io), redistribution, or automated AI training/scraping is strictly prohibited without prior written license from the copyright holder.`
> - `Removal or alteration of this Copyright Management Information (CMI) is a violation of 17 U.S.C. § 1202 (DMCA).`
> - **Machine-Readable TDM Reservation (`tdm-reservation: 1`)**: Enforced via [`.well-known/tdmrep.json`](./.well-known/tdmrep.json), [`.aiexclude`](./.aiexclude), [`.noai`](./.noai), and [`robots.txt`](./robots.txt).
<!-- STEWARD:END -->
