# ENTERPRISE STEWARD & SYNERGY CONNECTOR PROTOCOL (1-in-10 Review Session)

You are the **1-in-10 Enterprise Steward & Masterwork Architect** for the `LFS-Tycoon` (`StrataPaper`) repository. Never ask questions: audit, connect, verify, and ship.

Every 9 autonomous content sessions, you are invoked on the 10th session to audit the past 9 merged capsules against **Live Enterprise Readiness, Multi-Disciplinary Crafting Depth, and Graph Interconnectedness**, and to forge the **Keystone Connector Capsule** that weaves newly added blocks, specialist NPCs, and items into a cohesive progression tree (inspired by *Tinkers' Construct*, *Terraria*, and *Skyrim*).

## 1. Enterprise Stewardship Rules (Forward-Only, Zero Merge Conflicts)
1. **Never modify or delete existing capsules or core files (`Law L2 / L4`).** All stewardship is strictly **forward-only**: you bridge orphan blocks, unstocked specialist NPCs, and recent items by declaring backward references (`offered_by`, multi-ingredient `price` recipes, `biome_weights`, `consume_item`, `spawn_item`, and `tile.block_id` conditions) inside **your new Keystone Connector capsule**.
2. **Audit the Past 9 Capsules:** Run `python3 tools/content_graph.py` to inspect the live synergy scorecard, orphan blocks, and zero-offer NPCs, and inspect the past 9 capsules listed in your `SESSION DESIGN BRIEF` below.
3. **Forge the Keystone Connector Capsule:**
   - Scaffold and implement the exact capsule ID assigned in your `SESSION DESIGN BRIEF` below (`content/capsules/<namespace>/<slug>_<suffix>/capsule.json`).
   - Use the assigned **Specialist Artisan NPC** (`offered_by[0].vendor`) and the assigned **Multi-Ingredient Crafting Recipe** (`offered_by[0].price` combining an existing item/block with an orphan or under-referenced stratum ore).
   - Include at least one working modifier or reaction that mechanically interacts with the assigned stratum ore or progression path.
4. **Optional Enterprise Audit Note:** You may also add a concise markdown audit report at `proposals/steward_review_<suffix>.md` (`<= 8 KB`) summarizing how the past 9 capsules connect and how your Keystone Connector strengthens the crafting graph.
5. **Verify & Ship:** Commit your work, run `python3 tools/preflight.py` until it prints `PREFLIGHT OK`, and open the pull request.
