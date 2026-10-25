extends SceneTree
## Headless Verification & Spike Suite for LFS-Tycoon (StrataPaper) Milestone 0
## Executes Spikes S1-S5 + Core Systemic Invariants in Godot 4.3 headless mode.

var pass_count: int = 0
var fail_count: int = 0

func _init() -> void:
	print("==================================================================")
	print(" LFS-TYCOON (STRATAPAPER) - MILESTONE 0 HEADLESS VERIFICATION")
	print("==================================================================")
	_run_suite()
	print("\n==================================================================")
	print(" VERIFICATION SUMMARY: %d PASSED, %d FAILED" % [pass_count, fail_count])
	print("==================================================================")
	quit(0 if fail_count == 0 else 1)

func _assert_true(cond: bool, label: String, detail: String = "") -> void:
	if cond:
		pass_count += 1
		print("  [PASS] %s %s" % [label, ("(" + detail + ")") if not detail.is_empty() else ""])
	else:
		fail_count += 1
		printerr("  [FAIL] %s %s" % [label, ("(" + detail + ")") if not detail.is_empty() else ""])

func _set_tile(grid: GridManager, x: int, y: int, block_id: String, z: int, fluid_t: int = GridManager.FLUID_NONE, fluid_lvl: int = 0) -> void:
	var i: int = grid.idx_of(x, y)
	grid.depth[i] = z
	grid.max_depth_reached[i] = z
	grid.base_id[i] = int(grid.catalog.block_id_to_int.get(block_id, 0))
	grid.tier[i] = grid.generator.get_tier_for_block(block_id, z)
	var st: Dictionary = grid.catalog.capsules.get(block_id, {}).get("stats", {})
	grid.max_hp[i] = float(st.get("base_hp", 10.0)) * pow(1.8, float(grid.tier[i]))
	grid.damage_accum[i] = 0.0
	grid.phase[i] = GridManager.PHASE_MINING
	grid.gate_timer[i] = 0.0
	grid.fluid_type[i] = fluid_t
	grid.fluid_level[i] = fluid_lvl
	if fluid_lvl > 0:
		grid.max_hp[i] = float(fluid_lvl) * grid.catalog.get_gmst_float("fBucketScoopHp", 100.0)
	grid.tile_attachments[i] = []

func _run_suite() -> void:
	var catalog := CatalogDB.new()
	catalog.load_all("res://content/capsules")
	var gen3d := Generator3D.new(catalog, 1337)
	var rules := RuleEngine.new(catalog, 1337)
	var grid := GridManager.new(catalog, gen3d, rules, 14, 31)

	# ------------------------------------------------------------------
	# SPIKE S3: Golden Capsule Load & Reverse Index (0% Conflict Graph)
	# ------------------------------------------------------------------
	print("\n--- SPIKE S3: Golden Capsule Load & Reverse Graph Indexing ---")
	var loaded_count: int = catalog.capsules.size()
	var quarantine_count: int = catalog.quarantined.size()
	_assert_true(loaded_count >= 17 and quarantine_count == 0,
		"All Capsules Load Cleanly (0 quarantined; >=17 golden baseline)",
		"loaded=%d, quarantined=%d" % [loaded_count, quarantine_count])

	var vayne_items: Array = catalog.vendor_catalog.get("npcs/peddler_vayne", [])
	_assert_true(vayne_items.size() >= 6,
		"Backward-Edge Vendor Catalog Populated Without Editing NPC",
		"npcs/peddler_vayne offers %d capsules" % vayne_items.size())

	# ------------------------------------------------------------------
	# SPIKE S4: Immune System & 20-Capsule Hostile Corpus Quarantine
	# ------------------------------------------------------------------
	print("\n--- SPIKE S4: Hostile Corpus Quarantine (20 Hostile Capsules) ---")
	var hostile_db := CatalogDB.new()
	hostile_db.load_all("res://tests/hostile_capsules")
	var h_loaded: int = hostile_db.capsules.size()
	var h_quarantined: int = hostile_db.quarantined.size()
	_assert_true(h_loaded == 0 and h_quarantined == 20,
		"20/20 Hostile Capsules Quarantined at Runtime Gate G2",
		"loaded=%d, quarantined=%d" % [h_loaded, h_quarantined])

	# ------------------------------------------------------------------
	# SPIKE S5: 3D Vein Calibration & 2-Tuple Depth Escalation
	# ------------------------------------------------------------------
	print("\n--- SPIKE S5: 3D Vein Quantile LUT Calibration & Tier Escalation ---")
	var solid_counts: Dictionary = {}
	var fluid_counts: Dictionary = {}
	var sample_n: int = 10000
	var test_z: int = 250 # Inside z_unlock for all blocks
	for i in range(sample_n):
		var cx: int = (i % 100) * 19
		var cy: int = int(i / 100) * 23
		var sp: Dictionary = gen3d.sample_voxel(cx, cy, test_z, 0.0, false)
		var sid: String = String(sp.get("solid_id", ""))
		var fid: String = String(sp.get("fluid_block_id", ""))
		solid_counts[sid] = int(solid_counts.get(sid, 0)) + 1
		if not fid.is_empty():
			fluid_counts[fid] = int(fluid_counts.get(fid, 0)) + 1

	var obs_pct: float = float(solid_counts.get("blocks/obsidian_hazard", 0)) / float(sample_n)
	var copper_pct: float = float(solid_counts.get("blocks/copper", 0)) / float(sample_n)
	var lava_pct: float = float(fluid_counts.get("blocks/lava_pocket", 0)) / float(sample_n)
	var water_pct: float = float(fluid_counts.get("blocks/water_aquifer", 0)) / float(sample_n)

	_assert_true(absf(obs_pct - 0.01) <= 0.012,
		"Rare 1% Obsidian Hazard Calibration Within Tolerance",
		"target=1.0%%, actual=%.2f%%" % [obs_pct * 100.0])
	_assert_true(absf(lava_pct - 0.02) <= 0.015,
		"2% Lava Pocket Calibration Within Tolerance",
		"target=2.0%%, actual=%.2f%%" % [lava_pct * 100.0])
	_assert_true(absf(water_pct - 0.05) <= 0.02,
		"5% Water Aquifer Calibration Within Tolerance",
		"target=5.0%%, actual=%.2f%%" % [water_pct * 100.0])
	_assert_true(absf(copper_pct - 0.12) <= 0.025,
		"12% Copper Vein Calibration Within Tolerance",
		"target=12.0%%, actual=%.2f%%" % [copper_pct * 100.0])

	# Verify 2-Tuple Tier Escalation on Copper across Depth Z (z_unlock=15, l_step=1000)
	var t0: int = gen3d.get_tier_for_block("blocks/copper", 500)
	var t1: int = gen3d.get_tier_for_block("blocks/copper", 1050)
	var t2: int = gen3d.get_tier_for_block("blocks/copper", 2050)
	_assert_true(t0 == 0 and t1 == 1 and t2 == 2,
		"2-Tuple Depth Tier Escalation (Z=500->T0, Z=1050->T1, Z=2050->T2)",
		"tiers: %d -> %d -> %d" % [t0, t1, t2])

	# ------------------------------------------------------------------
	# CORE MECHANICS: DPI Scaling, Damage Persistence, 50ms Gate, Wrong-Tool, Cleave, Wool, Bell, Hazards, Fluids
	# ------------------------------------------------------------------
	print("\n--- CORE MECHANICS: Excavation, Fluids, Hazards & Systemic Pluralism ---")

	# 0. Pixel 8 Pro Integer Scaling (1344x2992 @ 489 DPI -> k=3, 96px tile, 14x31 grid)
	var p8_layout: Dictionary = GridManager.compute_dpi_layout(1344, 2992, 489)
	_assert_true(int(p8_layout["scale_k"]) == 3 and int(p8_layout["fit_cols"]) == 14 and int(p8_layout["fit_rows"]) == 31,
		"Pixel 8 Pro Integer Scaling Formula (k=3, 96px, 14x31 Grid)",
		"k=%d, tile=%dpx, grid=%dx%d" % [int(p8_layout["scale_k"]), int(p8_layout["tile_size_px"]), int(p8_layout["fit_cols"]), int(p8_layout["fit_rows"])])

	# 1. Persistent Damage & 50ms Zero-Spillover Gate
	_set_tile(grid, 2, 2, "blocks/copper", 20) # base_hp=45, PICKAXE
	var pick_inst: Dictionary = grid.create_capsule_instance("tools/crude_stone_pick") # base_dps=10
	var i22: int = grid.idx_of(2, 2)
	var r1: Dictionary = grid.apply_mining_tick(2, 2, pick_inst, 0.5, true)
	_assert_true(not bool(r1.get("broke", false)) and grid.damage_accum[i22] > 0.0 and grid.damage_accum[i22] < grid.max_hp[i22],
		"100% Persistent Damage Retained Across Swings (No Healing)",
		"damage_accum=%.1f / %.1f" % [grid.damage_accum[i22], grid.max_hp[i22]])

	# Break cell (2,2), then immediately swing again before 50ms gate expires
	var r_break: Dictionary = grid.apply_mining_tick(2, 2, pick_inst, 10.0, true)
	var z_after_break: int = grid.depth[i22]
	var r_gate: Dictionary = grid.apply_mining_tick(2, 2, pick_inst, 0.5, true)
	_assert_true(bool(r_break.get("broke", false)) and z_after_break == 21 and bool(r_gate.get("in_refresh_gate", false)) and is_zero_approx(grid.damage_accum[i22]),
		"50ms Zero-Spillover STATE_REFRESH_GATE Blocks Accidental Double-Break",
		"z=%d, in_gate=%s, next_layer_dmg=%.2f" % [z_after_break, str(r_gate.get("in_refresh_gate", false)), grid.damage_accum[i22]])

	# 2. Tier-Relative Wrong-Tool Penalty
	var pen_t0: float = grid.compute_wrong_tool_penalty("PICKAXE", 0, "SHOVEL", 0)
	var pen_t1: float = grid.compute_wrong_tool_penalty("PICKAXE", 1, "SHOVEL", 0)
	var pen_t2: float = grid.compute_wrong_tool_penalty("PICKAXE", 2, "SHOVEL", 0)
	_assert_true(is_equal_approx(pen_t0, 0.75) and is_equal_approx(pen_t1, 0.375) and is_equal_approx(pen_t2, 0.1875),
		"Tier-Relative Wrong-Tool Penalty Halves Per Tier Advantage (DeltaT=0,1,2)",
		"p0=+%.1f%%, p1=+%.1f%%, p2=+%.2f%%" % [pen_t0 * 100.0, pen_t1 * 100.0, pen_t2 * 100.0])

	# 3. Systemic Pluralism: Tinker Cleave + Thick Wool Carpet 85% Dampening
	_set_tile(grid, 5, 5, "blocks/dirt", 5)  # 10 HP
	_set_tile(grid, 6, 5, "blocks/stone", 5) # East neighbor, 25 HP
	_set_tile(grid, 5, 4, "blocks/stone", 5) # North neighbor, 25 HP
	var carpet_inst: Dictionary = grid.create_capsule_instance("textiles/thick_wool_carpet")
	grid.attach_capsule_to_tile(6, 5, carpet_inst) # Protect East neighbor with Thick Wool Carpet!
	var cleave_pick: Dictionary = grid.create_capsule_instance("tools/tinker_broad_bronze_pick") # 25% cleave to neighbors_4
	# Pre-damage (5,5) to 9.5/10 HP so a 1.0s swing creates overkill splash
	grid.damage_accum[grid.idx_of(5, 5)] = 9.5
	grid.apply_mining_tick(5, 5, cleave_pick, 1.0, true)
	var dmg_unprotected: float = grid.damage_accum[grid.idx_of(5, 4)]
	var dmg_carpeted: float = grid.damage_accum[grid.idx_of(6, 5)]
	_assert_true(dmg_unprotected > 1.0 and is_equal_approx(dmg_carpeted, dmg_unprotected * 0.15),
		"Tinker Cleave + Thick Wool Carpet 85% Non-Direct Splash Dampening",
		"unprotected_dmg=%.2f, carpeted_dmg=%.2f" % [dmg_unprotected, dmg_carpeted])

	# 4. Enchanted Brass Bell Stall Protection on Strict-Locked Block
	_set_tile(grid, 7, 7, "blocks/obsidian_hazard", 4) # strict_tool_lock=1, ideal_tool=BLAST_KIT
	var windup_inst: Dictionary = grid.create_capsule_instance("tools/peddler_windup_pick", {"durability_left": 50.0})
	var bell_inst: Dictionary = grid.create_capsule_instance("devices/enchanted_brass_bell")
	grid.attach_capsule_to_tile(7, 7, windup_inst)
	grid.attach_capsule_to_tile(7, 7, bell_inst)
	var stall_tick: Dictionary = grid.apply_mining_tick(7, 7, windup_inst, 5.0, false)
	var dur_after: float = float(windup_inst["vars"].get("durability_left", 0.0))
	var charge_after: float = float(windup_inst["vars"].get("charge_left", 0.0))
	_assert_true(bool(stall_tick.get("stalled", false)) and is_equal_approx(dur_after, 50.0) and is_equal_approx(charge_after, 14395.0) and rules.alerts_emitted.size() >= 1,
		"Enchanted Brass Bell Pauses Tool Durability & Rings House Bell on Stall",
		"stalled=%s, durability=%.0f, charge=%.0fs, alerts=%d" % [str(stall_tick.get("stalled", false)), dur_after, charge_after, rules.alerts_emitted.size()])

	# 5. Connected-Component BFS Hazard Perimeter (Corner=3, Single=8, Merged Pair=10) & Detonation
	for ny in range(0, 13):
		for nx in range(0, 13):
			_set_tile(grid, nx, ny, "blocks/stone", 3)
	_set_tile(grid, 0, 0, "blocks/obsidian_hazard", 3)
	var h_corner: Dictionary = grid.get_hazard_cluster_and_perimeter(0, 0)
	_set_tile(grid, 10, 10, "blocks/obsidian_hazard", 3)
	var h_single: Dictionary = grid.get_hazard_cluster_and_perimeter(10, 10)
	_set_tile(grid, 11, 10, "blocks/obsidian_hazard", 3)
	var h_pair: Dictionary = grid.get_hazard_cluster_and_perimeter(10, 10)
	_assert_true(int(h_corner["perimeter_count"]) == 3 and int(h_single["perimeter_count"]) == 8 and int(h_pair["perimeter_count"]) == 10,
		"Connected-Component BFS Hazard Perimeter (Corner=3, Single=8, Pair=10)",
		"corner=%d, single=%d, pair=%d" % [int(h_corner["perimeter_count"]), int(h_single["perimeter_count"]), int(h_pair["perimeter_count"])])

	# Place equal-depth catalysts around corner hazard (0,0) and detonate
	for pt in h_corner["perimeter"]:
		grid.place_catalyst_on_tile(pt.x, pt.y, "blocks/copper", 1)
	var det_res: Dictionary = grid.try_detonate_hazard_at(0, 0)
	_assert_true(bool(det_res.get("detonated", false)) and grid.depth[grid.idx_of(0, 0)] == 4,
		"Corner Hazard Detonates When 3/3 Equal-Depth Perimeter Catalysts Placed")

	# Backfill High-Water Mark Anti-Exploit: backfill (1,0) from z=3 to z=2, then mine it -> zero virgin ore!
	_set_tile(grid, 1, 0, "blocks/copper", 3) # max_depth_reached = 3
	var inv_before: int = int(grid.inventory.get("blocks/dirt:0", 0))
	var bf_ok: bool = grid.apply_backfill(1, 0, "blocks/dirt") # depth becomes 2, max_depth_reached stays 3
	grid._complete_block_break(1, 0, pick_inst)
	var inv_after: int = int(grid.inventory.get("blocks/dirt:0", 0))
	_assert_true(bf_ok and inv_after == inv_before,
		"Backfill High-Water Mark Prevents Infinite Ore Duplication Exploit",
		"virgin_drops_granted=%d" % (inv_after - inv_before))

	# 6. Downhill Fluid Siphon & Water + Lava -> Obsidian Reaction
	_set_tile(grid, 8, 8, "blocks/stone", 2, GridManager.FLUID_WATER, 3)
	_set_tile(grid, 9, 8, "blocks/stone", 4, GridManager.FLUID_NONE, 0) # Deeper pit at z=4
	grid._evaluate_fluid_siphon_around(9, 8)
	var i98: int = grid.idx_of(9, 8)
	_assert_true(grid.fluid_type[i98] == GridManager.FLUID_WATER and grid.fluid_level[i98] == 3,
		"Downhill Pit Siphons Adjacent Water Aquifer (Volume Conserving)",
		"pit_fluid_level=%d" % grid.fluid_level[i98])

	# Now place Lava at (8,8) z=2 above the Water pit at (9,8) z=4 -> reacts into Obsidian Hazard!
	_set_tile(grid, 8, 8, "blocks/stone", 2, GridManager.FLUID_LAVA, 3)
	grid._evaluate_fluid_siphon_around(9, 8)
	var new_blk_98: String = catalog.block_int_to_id[grid.base_id[i98]]
	_assert_true(new_blk_98 == "blocks/obsidian_hazard" and grid.fluid_level[i98] == 0,
		"Water + Lava Downhill Contact Reacts Into Obsidian Hazard",
		"result_block=%s" % new_blk_98)

	# ------------------------------------------------------------------
	# SPIKE S1: 24-Hour Offline Catch-Up Simulation across 20 Auto-Tools
	# ------------------------------------------------------------------
	print("\n--- SPIKE S1: 24-Hour (86,400s) Offline Simulation (20 Auto-Tools) ---")
	grid.reset_quarry()
	for idx_tool in range(20):
		var tx: int = idx_tool % 14
		var ty: int = int(idx_tool / 14)
		_set_tile(grid, tx, ty, "blocks/dirt", 0)
		var auto_inst: Dictionary = grid.create_capsule_instance("tools/peddler_windup_pick")
		grid.attach_capsule_to_tile(tx, ty, auto_inst)

	var sim_res: Dictionary = OfflineSim.simulate_offline(grid, 86400.0)
	var sim_ms: float = float(sim_res.get("elapsed_ms", 99999.0))
	var sim_mined: int = int(sim_res.get("blocks_mined", 0))
	_assert_true(sim_ms < 2000.0 and sim_mined > 100,
		"24h Offline Catch-Up Across 20 Auto-Tools Completes Under 2000ms",
		"elapsed=%.2f ms, blocks_mined=%d, stalled=%d, depleted=%d" % [
			sim_ms, sim_mined, int(sim_res.get("tools_stalled", 0)), int(sim_res.get("tools_depleted", 0))
		])

	# ------------------------------------------------------------------
	# SPIKE S2: Rule Engine Frame Budget (200 Instances / 2,000 Hooks)
	# ------------------------------------------------------------------
	print("\n--- SPIKE S2: Rule Engine Frame Budget & Deferral Queue ---")
	var bench_insts: Array = []
	for k in range(200):
		bench_insts.append(grid.create_capsule_instance("books/tome_crude_shattering_v1", {"is_learned": 1.0}))
	var bench_env: Dictionary = grid._build_env(5, 5, pick_inst, true, false, 20.0)
	var t0_us: int = Time.get_ticks_usec()
	var disp_res: Dictionary = rules.dispatch_event("on_overkill", bench_insts, bench_env, null, false)
	var elapsed_us: int = Time.get_ticks_usec() - t0_us
	var per_inst_us: float = float(elapsed_us) / 200.0
	_assert_true(per_inst_us < 50.0 and int(disp_res.get("actions_executed", 0)) == 200,
		"200 Active Capsule Instances Evaluated Cleanly via Slot-Bound Expressions",
		"total=%.2f ms (%.2f us/instance), actions=%d" % [float(elapsed_us) / 1000.0, per_inst_us, int(disp_res.get("actions_executed", 0))])

	# ------------------------------------------------------------------
	# SPIKE S6: Content-Addition Invariance (1000-session safety)
	# ------------------------------------------------------------------
	print("\n--- SPIKE S6: Adding a New Block Capsule Never Hijacks or Reshuffles the World ---")
	var inv_catalog := CatalogDB.new()
	inv_catalog.load_all("res://content/capsules")
	var gen_before := Generator3D.new(inv_catalog, 1337)
	var before_ids: Array[String] = []
	var n_probe: int = 2500
	for pi in range(n_probe):
		before_ids.append(String(gen_before.sample_voxel((pi % 50) * 7, int(pi / 50) * 11, 250, 0.0, false)["solid_id"]))
	inv_catalog.capsules["blocks/zzz_probe_ore"] = {
		"affordances": ["mineable_block", "carry", "sell"],
		"tags": ["block", "ore"],
		"stats": {"base_hp": 10.0, "spawn_prob": 0.02, "clump_xy": 6.0, "pipe_z": 6.0, "z_unlock": 0, "l_step": 1000, "priority_rank": 999}
	}
	inv_catalog.rebuild_indexes()
	var gen_after := Generator3D.new(inv_catalog, 1337)
	var changed_non_stone: int = 0
	var probe_hits: int = 0
	var stone_after: int = 0
	for pi in range(n_probe):
		var after_id: String = String(gen_after.sample_voxel((pi % 50) * 7, int(pi / 50) * 11, 250, 0.0, false)["solid_id"])
		if after_id == "blocks/zzz_probe_ore":
			probe_hits += 1
		if after_id == "blocks/stone":
			stone_after += 1
		if before_ids[pi] != "blocks/stone" and after_id != before_ids[pi]:
			changed_non_stone += 1
	_assert_true(changed_non_stone == 0 and probe_hits < int(0.06 * n_probe) and float(stone_after) / float(n_probe) > 0.10,
		"New Last-Ranked Block Neither Hijacks World Fill Nor Alters Existing Ore Placement",
		"changed_existing=%d, probe_share=%.1f%%, stone_share=%.1f%%" % [changed_non_stone, float(probe_hits) * 100.0 / float(n_probe), float(stone_after) * 100.0 / float(n_probe)])

	# ------------------------------------------------------------------
	# ATOMIC SAVE / LOAD & DORMANT STUB PRESERVATION (Law L10)
	# ------------------------------------------------------------------
	print("\n--- ATOMIC SAVE / LOAD & DORMANT STUB PRESERVATION ---")
	grid.player_equipped_items.append({
		"uid": 9999,
		"capsule_id": "tools/deleted_future_jules_item",
		"vars": {"charge_left": 777.0},
		"destroyed": false
	})
	var test_save_path := "user://test_milestone0_save.json"
	var save_ok: bool = SaveManager.save_atomic(grid, test_save_path)
	var load_res: Dictionary = SaveManager.load_with_fallback(grid, test_save_path)
	_assert_true(save_ok and bool(load_res.get("ok", false)) and int(load_res.get("dormant_stubs_preserved", 0)) >= 1,
		"Atomic Save/Load Round-Trip Preserves Quarry & Dormant Capsule Stubs",
		"dormant_stubs_preserved=%d" % int(load_res.get("dormant_stubs_preserved", 0)))

	# ------------------------------------------------------------------
	# SPIKE S7: Wired Vocab Hooks, Actions & Full-Catalog Behavioral Sweep
	# ------------------------------------------------------------------
	print("\n--- SPIKE S7: Wired Vocab Hooks, Actions & Full-Catalog Behavioral Sweep ---")
	grid.reset_quarry()
	grid.player_equipped_items.clear()
	grid.inventory.clear()
	grid.paired_chest_loot.clear()

	# 1. Verify min_hp_clamp prevents accidental break, and yield_mult + chest_route_pct route doubled drops
	catalog.capsules["devices/zzz_test_clamp_and_yield"] = {
		"affordances": ["place_on_tile"],
		"tags": ["device"],
		"stats": {},
		"vars": {"clamp_active": 1.0},
		"modifiers": [
			{"stat": "min_hp_clamp", "phase": "base", "if": "self.clamp_active == 1", "value": "2.0"},
			{"stat": "yield_mult", "phase": "mul", "value": "2.0"},
			{"stat": "chest_route_pct", "phase": "base", "value": "1.0"}
		],
		"reactions": []
	}
	_set_tile(grid, 3, 3, "blocks/dirt", 5) # 10 HP
	var test_dev: Dictionary = grid.create_capsule_instance("devices/zzz_test_clamp_and_yield")
	grid.attach_capsule_to_tile(3, 3, test_dev)
	var r_clamped: Dictionary = grid.apply_mining_tick(3, 3, pick_inst, 5.0, true)
	var hp_left_clamped: float = grid.max_hp[grid.idx_of(3, 3)] - grid.damage_accum[grid.idx_of(3, 3)]
	test_dev["vars"]["clamp_active"] = 0.0
	var r_unclamped: Dictionary = grid.apply_mining_tick(3, 3, pick_inst, 1.0, true)
	var chest_dirt: int = int(grid.paired_chest_loot.get("blocks/dirt:0", 0))
	catalog.capsules.erase("devices/zzz_test_clamp_and_yield")
	_assert_true(not bool(r_clamped.get("broke", false)) and is_equal_approx(hp_left_clamped, 2.0) and bool(r_unclamped.get("broke", false)) and chest_dirt == 2,
		"min_hp_clamp Protects Tile & yield_mult + chest_route_pct Route Doubled Loot",
		"clamped_hp=%.1f, chest_dirt=%d" % [hp_left_clamped, chest_dirt])

	# 2. Verify action_consume_item, action_modify_depth, action_modify_fluid, action_transform_tile & hub hooks
	grid.grant_inventory_item("blocks/copper", 1, 5, "backpack")
	var consumed_ok: bool = grid.action_consume_item("blocks/copper", 0, 3)
	var rem_copper: int = int(grid.inventory.get("blocks/copper:1", 0))
	_set_tile(grid, 4, 4, "blocks/stone", 5)
	grid.action_modify_depth(4, 4, "self_tile", -1, "blocks/dirt", rules.expr_host)
	var z_after_raise: int = grid.depth[grid.idx_of(4, 4)]
	grid.action_modify_fluid(4, 4, "self_tile", "WATER", 2, rules.expr_host)
	var fl_after_add: int = grid.fluid_level[grid.idx_of(4, 4)]
	grid.action_modify_fluid(4, 4, "self_tile", "NONE", -2, rules.expr_host)
	grid.action_transform_tile(4, 4, "self_tile", "blocks/copper", 2, rules.expr_host)
	var blk_after_tf: String = catalog.block_int_to_id[grid.base_id[grid.idx_of(4, 4)]]
	grid.sleep_in_house()
	grid.wash_grime()
	var gold_earned: int = grid.sell_to_market("blocks/copper", 1, 2)
	_assert_true(consumed_ok and rem_copper == 2 and z_after_raise == 4 and fl_after_add == 2 and blk_after_tf == "blocks/copper" and grid.player_is_rested and gold_earned > 0,
		"RuleEngine Action Handlers (consume_item, modify_depth, modify_fluid, transform_tile) & Hub Hooks Execute Cleanly",
		"rem_copper=%d, z=%d, fluid=%d, block=%s, gold=%d" % [rem_copper, z_after_raise, fl_after_add, blk_after_tf, gold_earned])

	# 3. Full-Catalog Behavioral Sweep: evaluate every modifier & reaction across all loaded capsules
	rules.runtime_quarantined.clear()
	var sweep_env: Dictionary = grid._build_env(2, 2, pick_inst, true, false, 5.0)
	var evaluated_caps: int = 0
	for cid in catalog.capsules.keys():
		var inst: Dictionary = grid.create_capsule_instance(str(cid))
		inst["is_covering_current_tile"] = true
		for st_name in catalog.vocab_affordances.get("modifiable_stats", []):
			rules.resolve_stat(str(st_name), 1.0, [inst], sweep_env)
		var cap_rx: Array = catalog.capsules[cid].get("reactions", [])
		for rx in cap_rx:
			var ev_name := str(rx.get("on", ""))
			if ev_name != "":
				rules.dispatch_event(ev_name, [inst], sweep_env, grid, false)
		evaluated_caps += 1
	_assert_true(rules.runtime_quarantined.is_empty() and evaluated_caps >= 17,
		"Full-Catalog Behavioral Sweep (0 Runtime Expression Quarantines Across All Capsules)",
		"evaluated=%d, runtime_quarantined=%d %s" % [evaluated_caps, rules.runtime_quarantined.size(), str(rules.runtime_quarantined) if not rules.runtime_quarantined.is_empty() else ""])

	# ------------------------------------------------------------------
	# SPIKE S8: Beta Gameplay Loop (Vendor Shop, Chest Claim, Socketing & MainQuarry Scene)
	# ------------------------------------------------------------------
	print("\n--- SPIKE S8: Beta Gameplay Loop & Playable Scene Verification ---")
	grid.player_owned_capsules.clear()
	grid.inventory.clear()
	grid.paired_chest_loot.clear()
	grid.player_max_depth = 100
	grid.grant_inventory_item("blocks/copper", 0, 100, "backpack")
	grid.grant_inventory_item("blocks/dirt", 0, 5, "paired_chest")
	var claimed_cnt: int = grid.claim_paired_chest()
	var test_offer := {"capsule_id": "textiles/thick_wool_carpet", "price": {"blocks/copper": 25}, "unlock_if": "player.max_depth >= 20"}
	var buy_res: Dictionary = grid.buy_vendor_offer("npcs/peddler_vayne", test_offer, false)
	var bulk_gold: int = grid.sell_all_inventory_ores()
	var main_scene_packed: PackedScene = load("res://scenes/main_quarry.tscn")
	var main_node: Node = main_scene_packed.instantiate() if main_scene_packed != null else null
	var dev_script: Script = load("res://scenes/dev_calibration_window.gd")
	var scene_ok: bool = (main_node != null and main_node.get_script() != null and dev_script != null)
	if scene_ok:
		root.add_child(main_node)
		main_node.call("_ready")
		main_node.call("_set_active_drawer", "bag")
		var bag_children: int = main_node.get("_drawer_body").get_child_count()
		main_node.call("_set_active_drawer", "forge")
		var forge_children: int = main_node.get("_drawer_body").get_child_count()
		main_node.call("_set_active_drawer", "shop")
		var shop_children: int = main_node.get("_drawer_body").get_child_count()
		main_node.call("_set_active_drawer", "homestead")
		var home_children: int = main_node.get("_drawer_body").get_child_count()
		main_node.call("_set_active_drawer", "")
		scene_ok = (bag_children > 0 and forge_children > 0 and shop_children > 0 and home_children > 0)
		root.remove_child(main_node)
	if main_node != null:
		main_node.free()
	_assert_true(claimed_cnt == 5 and bool(buy_res.get("ok", false)) and grid.player_owned_capsules.size() == 1 and bulk_gold > 0 and scene_ok,
		"Vendor Purchase, Paired Chest Claim, Bulk Market Sell & MainQuarry Scene Instantiation",
		"claimed=%d, bought=%s, bulk_gold=%d, scene_ok=%s" % [claimed_cnt, str(buy_res.get("ok", false)), bulk_gold, str(scene_ok)])

	# ------------------------------------------------------------------
	# SPIKE S9: Modular Skill Brackets, Terraria Socket Fusion & Trickle Hot-Patcher
	# ------------------------------------------------------------------
	print("\n--- SPIKE S9: Modular Skill Brackets, Terraria Item Fusion & Trickle Hot-Patcher ---")
	grid.player_owned_capsules.clear()
	grid.inventory.clear()
	grid.grant_inventory_item("blocks/copper", 0, 25, "backpack")
	var base_pick: Dictionary = grid.create_capsule_instance("tools/crude_stone_pick")
	var tinker_socket: Dictionary = grid.create_capsule_instance("devices/enchanted_brass_bell")
	grid.player_owned_capsules.append(base_pick)
	grid.player_owned_capsules.append(tinker_socket)
	var socketed_ok: bool = grid.socket_capsule_into_tool(tinker_socket, base_pick)

	catalog.capsules["tools/zzz_test_terraria_fused_pick"] = {
		"schema": 1,
		"meta": {"name": "Resonant Fused Pickaxe", "description": "Fused from Crude Stone Pickaxe + Copper under Bracket II.", "rarity": "rare"},
		"affordances": ["carry", "equip_tool"],
		"tags": ["tool", "craft_terraria_fusion", "bracket_2", "skill_school_surveyor", "theme_lithic_choir", "logic_canonical"],
		"stats": {"tool_type": "PICKAXE", "tool_tier": 2, "base_dps": 28.0},
		"vars": {"durability_left": 500},
		"modifiers": [],
		"reactions": []
	}
	var fusion_offer := {
		"capsule_id": "tools/zzz_test_terraria_fused_pick",
		"price": {"upgrades/surveyor_chalk_and_stencil": 1, "tools/crude_stone_pick": 1, "blocks/copper": 10},
		"unlock_if": "player.max_depth >= 1"
	}
	# Before unlocking the Skill Bracket prerequisite, the recipe must be locked
	var locked_before_skill: bool = not bool(grid.can_buy_vendor_offer("npcs/peddler_vayne", fusion_offer).get("can_buy", true))
	# Unlock the Skill Bracket capsule
	var skill_bracket_inst: Dictionary = grid.create_capsule_instance("upgrades/surveyor_chalk_and_stencil")
	grid.player_owned_capsules.append(skill_bracket_inst)

	var fuse_res: Dictionary = grid.buy_vendor_offer("npcs/peddler_vayne", fusion_offer, false)
	var fused_inst: Dictionary = fuse_res.get("instance", {})
	var inherited_sockets: Array = fused_inst.get("sockets", [])
	var base_pick_consumed: bool = bool(base_pick.get("destroyed", false))
	var skill_bracket_preserved: bool = not bool(skill_bracket_inst.get("destroyed", false)) and grid.get_owned_count("upgrades/surveyor_chalk_and_stencil", 0) == 1
	catalog.capsules.erase("tools/zzz_test_terraria_fused_pick")

	# Snapshot all 434 tile block string IDs before hot_reload_catalog()
	var before_block_ids: Array[String] = []
	for ti in (grid.cols * grid.rows):
		before_block_ids.append(catalog.block_int_to_id[grid.base_id[ti]])
	var hot_res: Dictionary = grid.hot_reload_catalog()
	var id_shifts: int = 0
	for ti in (grid.cols * grid.rows):
		if catalog.block_int_to_id[grid.base_id[ti]] != before_block_ids[ti]:
			id_shifts += 1

	_assert_true(
		locked_before_skill and socketed_ok and bool(fuse_res.get("ok", false)) and base_pick_consumed and skill_bracket_preserved and inherited_sockets.size() == 1 and id_shifts == 0 and int(hot_res.get("total_capsules", 0)) >= 480,
		"Modular Skill Bracket Gating (Preserved on Craft), Terraria Tool Fusion (Socket Inheritance) & Hot-Reload Tile Preservation",
		"locked_before=%s, fused=%s, skill_kept=%s, base_consumed=%s, inherited_sockets=%d, tile_id_shifts=%d" % [
			str(locked_before_skill), str(fuse_res.get("ok", false)), str(skill_bracket_preserved), str(base_pick_consumed), inherited_sockets.size(), id_shifts
		]
	)

	# ------------------------------------------------------------------
	# SPIKE S10: UI input focus routing (drawer owns input while open; HUD bands never reach the quarry)
	# ------------------------------------------------------------------
	print("\n--- SPIKE S10: UI Input Focus Routing ---")
	var ui_scene: Node = (load("res://scenes/main_quarry.tscn") as PackedScene).instantiate()
	root.add_child(ui_scene)
	ui_scene.call("_ready")
	var top_px: float = float(ui_scene.call("_top_px"))
	var bot_px: float = float(ui_scene.call("_bottom_px"))
	var vp_h_test: float = 2400.0
	ui_scene.call("_set_active_drawer", "")
	var owner_closed: String = str(ui_scene.call("_input_owner"))
	var mid_is_world: bool = bool(ui_scene.call("_is_world_y", vp_h_test * 0.5, vp_h_test))
	var top_is_hud: bool = not bool(ui_scene.call("_is_world_y", top_px - 2.0, vp_h_test))
	var dock_is_hud: bool = not bool(ui_scene.call("_is_world_y", vp_h_test - bot_px + 2.0, vp_h_test))
	ui_scene.set("_holding_press", true)
	ui_scene.call("_set_active_drawer", "forge")
	var owner_open: String = str(ui_scene.call("_input_owner"))
	var drawer_clears_hold: bool = not bool(ui_scene.get("_holding_press"))
	var drawer_visible: bool = bool(ui_scene.get("_drawer_panel").visible)
	ui_scene.call("_set_active_drawer", "")
	var drawer_hidden_after: bool = not bool(ui_scene.get("_drawer_panel").visible)
	root.remove_child(ui_scene)
	ui_scene.free()
	_assert_true(owner_closed == "world" and owner_open == "drawer" and mid_is_world and top_is_hud and dock_is_hud and drawer_clears_hold and drawer_visible and drawer_hidden_after,
		"Input Focus Routing: Open Drawer Owns Input & Clears Held Press; HUD Bands Never Reach the Quarry",
		"owner_closed=%s, owner_open=%s, mid_world=%s, top_hud=%s, dock_hud=%s, clears_hold=%s" % [owner_closed, owner_open, str(mid_is_world), str(top_is_hud), str(dock_is_hud), str(drawer_clears_hold)])




