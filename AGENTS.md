# AGENTS.md — LFS-Tycoon (Codename: StrataPaper)
**Engine**: Godot 4.3 (Compatibility / Mobile) + Python 3.10+ (stdlib-only tooling)
**Architecture**: Antifragile drop-in Capsule engine (Laws L1–L12, see [JULES_CAPSULE_CONTRACT.md](JULES_CAPSULE_CONTRACT.md))

Every item, tool, block, skill book, textile, consumable, upgrade, biome and NPC is a self-contained **Capsule**:
`content/capsules/<namespace>/<slug>/capsule.json`. There are no registry files. Content ships straight live:
a pull request that passes the gates is merged automatically, and a red content commit on `main` is reverted automatically.

---

## 1. AUTONOMOUS SESSION PROTOCOL (follow exactly; never ask questions, decide and ship)

Your job each session: add **one** new, well-designed capsule (up to 3 only if one idea truly needs a small family).

1. **Sync.** `git fetch origin main && git rebase origin/main` (run `git fetch --unshallow origin || true` first if the clone is shallow).
2. **Get your brief.** If your task prompt already contains a `SESSION DESIGN BRIEF` (the automated factory always includes one), that is your assignment. Otherwise run `python3 tools/pick_brief.py` to get a randomized, coverage-weighted one. Follow it, use its exact id suffix, and never re-roll it. Apply any "Recent gate failures to avoid" listed in the prompt.
3. **Learn the ground.** `python3 tools/generate_context.py`, then read `AI_CONTEXT_MANIFEST.md`, the brief's `Imitate:` capsule, and [JULES_CAPSULE_CONTRACT.md](JULES_CAPSULE_CONTRACT.md). Existing solutions to your friction are listed in the brief: be meaningfully different.
4. **Scaffold.** `python3 tools/new_capsule.py --id <namespace>/<slug>_<suffix> --archetype <archetype> --name "Display Name"` using the brief's id (the slug MUST end with the brief's 4-hex suffix; this prevents collisions between parallel sessions).
5. **Design and edit** only your own `capsule.json`. Include the brief's required tags (`solves_<friction>`, `path_<type>`, or `world_<kind>`). Write a vivid `meta.description` in the game's voice.
6. **Commit** (message: `content: add <id>`), then **verify:** `python3 tools/preflight.py`. Fix every error it reports, re-commit, re-run. It must print `PREFLIGHT OK`.
   * If a clever mechanic will not validate after 5 honest attempts, **simplify the design** (fewer reactions, plain modifiers) and ship that. Never ship nothing, never touch shared files to force a pass.
7. **Submit** by opening a pull request (in automated sessions the pull request is created for you when you finish). The gate verifies it against trusted tools from `main` and merges it automatically; failures are closed and fed back to future sessions as lessons. Final reply: just the capsule id(s).

If a design genuinely needs a verb the vocabulary lacks, still ship your best vocabulary-legal capsule, and optionally add `proposals/<slug>_<suffix>.md` (<=16 KB) describing the missing verb. Proposals are allowed additions; vocabulary edits are not.

---

## 2. DESIGN PILLARS (what "good" means here)

* **FTB depth in a graph-paper interface.** The surface is simple (tap tiles, mine, trade). Depth comes from many interacting capsules, never from complicated screens.
* **Multiple paths to the same relief.** The same friction can be eased by a vendor disposable, a skill book, an enchanter service, a forged tool, a field textile, a charm, a profession perk, and more. Every path has its own quirks, limits, pros and cons. Make yours distinct, not a clone.
* **Ease is earned, friction is currency.** Never remove a friction outright. Ease must cost something: money, exotic materials, unlock gates, duration, wear, maintenance or a trade-off. Granular single-purpose options beat bundles; a bundle may exist only as a very expensive, unlock-gated NPC package.
* **First level is clumsy.** Early versions are weak and rough (a cleave book that splashes only 5–10% of overkill, for example). Better versions arrive later as separate capsules.
* **Mercy through upgrades, not defaults.** Miss-tap relief, previews and HUD aids are purchasable single-function capsules.
* **Hard limits.** No player stamina, mana or health bars. Auto-tools run on their own timers, fully decoupled from the player's food and sleep perks. House amenities are perks, never penalties. Mining never becomes instant: the engine's 1.0 s minimum per block stays true. Durability is a soft system, never punishing. Damage persists and never heals.
* **Nothing strictly dominates.** Every capsule needs at least one deliberate limiter or trade-off, and a believable price (via `offered_by`) in existing block currencies.
* **Everything is data.** Numbers live in `stats`; shared tunables live in `vocab/gmst.json`. Never hard-code balance anywhere else.
* **World blocks are budgeted.** `blocks/stone` is the fixed world fill. Keep new blocks' `stats.spawn_prob` small (<=0.03) and use `z_unlock` / optional `z_max`; G1 rejects any depth where solid spawn probabilities sum above 0.90.

---

## 3. NON-NEGOTIABLE LAWS (zero merge conflicts)

1. **Additions only (L2/L4).** A session may only ADD new files under its own `content/capsules/<namespace>/<slug>/` (and optional `proposals/`). Never edit or delete anything else: not other capsules, not `engine/`, `vocab/`, `tools/`, `tests/`, `design/`, `factory/`, `.github/`. The path guard rejects violations and the PR will not merge.
2. **Path-derived identity (L2).** Do not add an `"id"` that disagrees with the folder path. The ID is always `<namespace>/<slug>`.
3. **Edges point backward (L3).** Sold by an NPC or spawned in a biome? Declare `offered_by` (with `vendor`, `price`, optional `unlock_if`) or `biome_weights` inside YOUR capsule. Never edit the NPC or biome.
4. **Closed verbs, open composition (L1).** Only events in `vocab/events.json`, actions in `vocab/actions.json`, and affordances/stats in `vocab/affordances.json`. Every `shared.*` register you reference must already be declared in `vocab/shared_vars.json`.
5. **Deterministic expressions (L7).** In `"if"` / `"value"` strings never call `randf()`, `OS`, `FileAccess` or engine singletons. Use `roll(prob)` for seeded randomness. Division by a possibly-zero value is rejected.
6. **Bounded cascades (L8).** At most 8 actions per hook; any `deal_damage` reacting to damage must guard with `ctx.is_secondary_damage == 0`.
7. **Strict JSON.** No comments, no trailing commas, no duplicate keys.

---

## 4. TOOLS (zero install; all run in under 2 seconds)

| Command | Purpose |
| :--- | :--- |
| `python3 tools/pick_brief.py` | Your randomized assignment for this session |
| `python3 tools/generate_context.py` | Builds untracked `AI_CONTEXT_MANIFEST.md` and `GAP_MAP.md` (never commit them) |
| `python3 tools/new_capsule.py ...` | Scaffolds a valid capsule from an archetype |
| `python3 tools/check_capsules.py --strict` | Gate G1 static lint (also run by preflight) |
| `python3 tools/preflight.py` | Everything CI checks that you can check locally |

Optional, when Godot 4.3 is installed: `godot --headless --path . --import --quit && godot --headless --path . -s tests/run_all_spikes.gd` (Gate G2).
