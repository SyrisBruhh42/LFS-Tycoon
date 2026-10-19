# AGENTS.md — LFS-Tycoon (Codename: StrataPaper)
**Engine**: Godot 4.3 (Compatibility / Mobile) + Python 3.10+ (Zero-Install Stdlib Validator)  
**Architecture**: Antifragile Drop-In Reactive Capsule Engine (Law Set L1–L12)

---

## 1. Quick Start for Google Jules / AI Coding Sessions

Every item, tool, block, skill book, textile covering, consumable, upgrade, biome, or NPC in this game is a self-contained **Capsule** located in its own folder under `content/capsules/<namespace>/<slug>/capsule.json`.

### Step 0: Unshallow Git (Required in Jules Cloud VMs)
If running path-guard diffs in a shallow clone, run:
```bash
git fetch --unshallow origin || true
```

### Step 1: Generate Live Context & Niche Gap Map (Do Not Commit Output)
```bash
python3 tools/generate_context.py
```
This generates `AI_CONTEXT_MANIFEST.md` (all existing tags, shared vars, blocks, biomes, and NPCs) and `GAP_MAP.md` (under-used event × action × affordance niches). **Never commit `AI_CONTEXT_MANIFEST.md` or `GAP_MAP.md`.**

### Step 2: Scaffold a New Capsule (Gate G0)
```bash
python3 tools/new_capsule.py --id <namespace>/<slug> --archetype <tool|textile|book|consumable|device|upgrade|block|biome|npc> --name "Display Name"
```

### Step 3: Edit & Validate Locally (Gate G1 — Mandatory Before Commit)
Edit only `content/capsules/<namespace>/<slug>/capsule.json`, then run:
```bash
python3 tools/check_capsules.py --strict
```
* **Zero setup required:** `check_capsules.py` uses Python stdlib only and completes in `<2s`.
* **Do not commit** unless `check_capsules.py --strict` exits with code `0` (`ALL CAPSULES VALID`).

### Step 4: Headless Engine & Spike Verification (Gate G2 — When Godot 4.3 Is Available)
```bash
godot --headless --path . --import --quit
godot --headless --path . -s tests/run_all_spikes.gd
```

---

## 2. Non-Negotiable Content Session Laws (Zero Merge Conflicts)

1. **One Folder Per Session (Law L2 & L4):** A content session may ONLY create or edit files inside its own assigned `content/capsules/<namespace>/<slug>/` directory. Never edit `engine/`, `vocab/`, `tools/`, `tests/`, or another capsule's folder.
2. **Path-Derived Identity (Law L2):** Do not put an `"id"` field inside `capsule.json` that disagrees with the folder path. The canonical ID is always `<namespace>/<slug>`.
3. **Edges Point Backward (Law L3):** If your new item is sold by an NPC, crafted from existing blocks, or spawns in a biome, declare `offered_by`, `recipe`, or `biome_weights` inside **your new capsule**. Never edit the NPC or biome file to add your item.
4. **Closed Verbs, Open Composition (Law L1):** Only use events listed in `vocab/events.json`, actions in `vocab/actions.json`, and affordances/stats in `vocab/affordances.json`.
5. **Deterministic Expressions Only (Law L7):** In `"if"` and `"value"` strings, never call `randf()`, `OS`, `FileAccess`, or engine singletons. Use `roll(prob)` or `ctx.rng` for seeded randomness.
6. **Read the Full Contract:** See [JULES_CAPSULE_CONTRACT.md](JULES_CAPSULE_CONTRACT.md) for complete schemas and examples.
