class_name GridManager
extends RefCounted
## Contiguous SoA Quarry State Engine, DPI Integer Scaler (D1 Freeze & Pan),
## Persistent HP + 50ms Zero-Spillover Gate, Event-Driven Cellular Fluids & BFS Connected Hazards.

const PHASE_MINING: int = 0
const PHASE_REFRESH_GATE: int = 1

const FLUID_NONE: int = 0
const FLUID_WATER: int = 1
const FLUID_LAVA: int = 2

const ENTITY_NONE: int = -1
const ENTITY_LOST_CAT: int = 1

var catalog: CatalogDB
var generator: Generator3D
var rules: RuleEngine

# Frozen logical quarry dimensions (Decision D1)
var cols: int = 14
var rows: int = 31
var scale_k: int = 3
var tile_size_px: int = 96
var pan_offset_px: Vector2 = Vector2.ZERO

# Contiguous Structure-of-Arrays (SoA) per-tile buffers
var depth: PackedInt32Array = PackedInt32Array()
var max_depth_reached: PackedInt32Array = PackedInt32Array()
var base_id: PackedInt32Array = PackedInt32Array()
var tier: PackedInt32Array = PackedInt32Array()
var damage_accum: PackedFloat32Array = PackedFloat32Array()
var max_hp: PackedFloat32Array = PackedFloat32Array()
var phase: PackedInt32Array = PackedInt32Array()
var gate_timer: PackedFloat32Array = PackedFloat32Array()
var placed_catalyst_id: PackedInt32Array = PackedInt32Array()
var placed_catalyst_tier: PackedInt32Array = PackedInt32Array()
var fluid_type: PackedInt32Array = PackedInt32Array()
var fluid_level: PackedInt32Array = PackedInt32Array()
var dynamic_entity_id: PackedInt32Array = PackedInt32Array()

# Active capsule instances on tiles (e.g. wool carpets, stationed auto-tools, bells)
var tile_attachments: Array = []           # Array[Array[Dictionary]] indexed by cell idx
var player_equipped_items: Array = []      # Array[Dictionary] (equipped tool, read books, active buffs)
var inventory: Dictionary = {}             # "capsule_id:tier" -> int count
var paired_chest_loot: Dictionary = {}     # "capsule_id:tier" -> int count
var next_instance_uid: int = 1

# Player & Quest state
var player_max_depth: int = 0
var player_grime: float = 0.0
var player_is_rested: bool = true
var quest_lost_cat_active: bool = false
var lost_cat_hp: float = 10.0


func _init(p_catalog: CatalogDB, p_generator: Generator3D, p_rules: RuleEngine, p_cols: int = -1, p_rows: int = -1) -> void:
	catalog = p_catalog
	generator = p_generator
	rules = p_rules
	cols = p_cols if p_cols > 0 else catalog.get_gmst_int("fDefaultCols", 14)
	rows = p_rows if p_rows > 0 else catalog.get_gmst_int("fDefaultRows", 31)
	_allocate_buffers()
	reset_quarry()


## Universal Integer Scaling Formula: k = max(1, round((DPI * 0.197) / 32))
static func compute_dpi_layout(screen_w: int, screen_h: int, dpi: int, base_px: int = 32, target_inch: float = 0.197) -> Dictionary:
	var k := maxi(1, int(round((float(dpi) * target_inch) / float(base_px))))
	var t_px := base_px * k
	var c := maxi(1, int(floor(float(screen_w) / float(t_px))))
	var r := maxi(1, int(floor(float(screen_h) / float(t_px))))
	return {
		"scale_k": k,
		"tile_size_px": t_px,
		"fit_cols": c,
		"fit_rows": r,
		"margin_x": screen_w - (c * t_px),
		"margin_y": screen_h - (r * t_px)
	}


## Decision D1: Updates integer scale k for the current display while keeping quarry (cols, rows) frozen.
func apply_viewport_scaling(screen_w: int, screen_h: int, dpi: int) -> Dictionary:
	var layout := compute_dpi_layout(
		screen_w,
		screen_h,
		dpi,
		catalog.get_gmst_int("fBaseTilePx", 32),
		catalog.get_gmst_float("fTargetTileInch", 0.197)
	)
	scale_k = int(layout["scale_k"])
	tile_size_px = int(layout["tile_size_px"])
	var world_w := float(cols * tile_size_px)
	var world_h := float(rows * tile_size_px)
	var max_pan_x := maxf(0.0, world_w - float(screen_w))
	var max_pan_y := maxf(0.0, world_h - float(screen_h))
	pan_offset_px.x = clampf(pan_offset_px.x, 0.0, max_pan_x)
	pan_offset_px.y = clampf(pan_offset_px.y, 0.0, max_pan_y)
	layout["world_w_px"] = int(world_w)
	layout["world_h_px"] = int(world_h)
	layout["pan_needed"] = (max_pan_x > 0.0 or max_pan_y > 0.0)
	return layout


func idx_of(x: int, y: int) -> int:
	return y * cols + x


func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and x < cols and y >= 0 and y < rows


func _allocate_buffers() -> void:
	var n := cols * rows
	depth.resize(n)
	max_depth_reached.resize(n)
	base_id.resize(n)
	tier.resize(n)
	damage_accum.resize(n)
	max_hp.resize(n)
	phase.resize(n)
	gate_timer.resize(n)
	placed_catalyst_id.resize(n)
	placed_catalyst_tier.resize(n)
	fluid_type.resize(n)
	fluid_level.resize(n)
	dynamic_entity_id.resize(n)
	tile_attachments.resize(n)
	for i in n:
		tile_attachments[i] = []


func reset_quarry() -> void:
	var n := cols * rows
	for y in rows:
		for x in cols:
			var i := idx_of(x, y)
			depth[i] = 0
			max_depth_reached[i] = 0
			damage_accum[i] = 0.0
			phase[i] = PHASE_MINING
			gate_timer[i] = 0.0
			placed_catalyst_id[i] = -1
			placed_catalyst_tier[i] = 0
			dynamic_entity_id[i] = ENTITY_NONE
			tile_attachments[i] = []
			_populate_tile_from_generator(x, y, 0, 0.0)


func create_capsule_instance(cap_id: String, extra_vars: Dictionary = {}) -> Dictionary:
	var cap_def: Dictionary = catalog.capsules.get(cap_id, {})
	var inst_vars: Dictionary = cap_def.get("vars", {}).duplicate(true)
	for k in extra_vars.keys():
		inst_vars[k] = float(extra_vars[k])
	var inst := {
		"uid": next_instance_uid,
		"capsule_id": cap_id,
		"vars": inst_vars,
		"destroyed": false,
		"is_covering_current_tile": false
	}
	next_instance_uid += 1
	return inst


func attach_capsule_to_tile(x: int, y: int, inst: Dictionary) -> void:
	if not in_bounds(x, y):
		return
	var i := idx_of(x, y)
	tile_attachments[i].append(inst)


## Computes active non-hazard depth percentiles (P10, P50, P90) and directional local imbalance.
func compute_depth_percentiles() -> Dictionary:
	var active_depths: Array[int] = []
	var n := cols * rows
	for i in n:
		var bid_str := catalog.block_int_to_id[base_id[i]]
		var st: Dictionary = catalog.capsules.get(bid_str, {}).get("stats", {})
		if int(st.get("is_hazard", 0)) == 0:
			active_depths.append(depth[i])
	if active_depths.is_empty():
		return {"p10": 0.0, "p50": 0.0, "p90": 0.0}
	active_depths.sort()
	var sz := active_depths.size()
	return {
		"p10": float(active_depths[int(0.10 * (sz - 1))]),
		"p50": float(active_depths[int(0.50 * (sz - 1))]),
		"p90": float(active_depths[int(0.90 * (sz - 1))])
	}


func compute_local_imbalance(x: int, y: int, pcts: Dictionary = {}) -> float:
	if pcts.is_empty():
		pcts = compute_depth_percentiles()
	var z := float(depth[idx_of(x, y)])
	var p50 := float(pcts.get("p50", 0.0))
	var p10 := float(pcts.get("p10", 0.0))
	var w_local := catalog.get_gmst_float("fImbalanceLocalWeight", 1.0)
	var w_dec := catalog.get_gmst_float("fImbalanceDecileWeight", 0.35)
	return w_local * maxf(0.0, z - p50) + w_dec * maxf(0.0, z - p10)


## Universal Wrong-Tool Penalty & High-Tier Compensation: 0.75 * (0.5 ^ max(0, T_tool - T_req))
func compute_wrong_tool_penalty(tool_type_str: String, tool_tier_val: int, ideal_tool_str: String, req_tier_val: int) -> float:
	if tool_type_str == ideal_tool_str or ideal_tool_str == "NONE":
		return 0.0
	var base_pen := catalog.get_gmst_float("fWrongToolPenaltyBase", 0.75)
	var decay := catalog.get_gmst_float("fWrongToolTierDecay", 0.50)
	var delta_t := maxi(0, tool_tier_val - req_tier_val)
	return base_pen * pow(decay, float(delta_t))


## Applies a mining swing/tick on (x, y) with the specified tool instance and delta time dt.
func apply_mining_tick(x: int, y: int, tool_inst: Dictionary, dt: float, is_direct_tap: bool = true) -> Dictionary:
	if not in_bounds(x, y):
		return {"broke": false, "damage_dealt": 0.0}
	var i := idx_of(x, y)

	# Zero-Spillover Refresh Gate (50ms pause)
	if phase[i] == PHASE_REFRESH_GATE:
		return {"broke": false, "damage_dealt": 0.0, "in_refresh_gate": true}

	# Check if Lost Cat quest entity is sitting on this tile (1-damage jump loop)
	if dynamic_entity_id[i] == ENTITY_LOST_CAT and is_direct_tap:
		lost_cat_hp -= 1.0
		dynamic_entity_id[i] = ENTITY_NONE
		if lost_cat_hp <= 0.0:
			quest_lost_cat_active = false
			grant_inventory_item("quest/lost_cat", 0, 1, "backpack")
			return {"broke": false, "damage_dealt": 1.0, "cat_captured": true}
		else:
			_jump_lost_cat_from(x, y)
			return {"broke": false, "damage_dealt": 1.0, "cat_jumped": true}

	var tool_cap: Dictionary = catalog.capsules.get(str(tool_inst.get("capsule_id", "")), {})
	var tool_st: Dictionary = tool_cap.get("stats", {})
	var tool_type_str := str(tool_st.get("tool_type", "PICKAXE"))
	var tool_tier_val := int(tool_st.get("tool_tier", 0))
	var base_dps := float(tool_st.get("base_dps", 10.0))

	# Determine target block or fluid overlay
	var is_fluid_active := (fluid_level[i] > 0 and fluid_type[i] != FLUID_NONE)
	var blk_id := catalog.block_int_to_id[base_id[i]]
	var blk_st: Dictionary = catalog.capsules.get(blk_id, {}).get("stats", {})
	var ideal_tool_str := "BUCKET" if is_fluid_active else str(blk_st.get("ideal_tool", "PICKAXE"))
	var strict_locked := true if is_fluid_active else (int(blk_st.get("strict_tool_lock", 0)) == 1)
	var req_tier_val := tier[i]

	var active_insts := _gather_active_instances(i, tool_inst)
	var env := _build_env(x, y, tool_inst, is_direct_tap, false, 0.0)

	# Check strict tool lock (e.g. hitting Water or Obsidian with a Pickaxe deals 0 damage)
	if strict_locked and tool_type_str != ideal_tool_str:
		var stall_res := rules.dispatch_event("on_zero_damage_stall", active_insts, env, self)
		var inst_vars: Dictionary = tool_inst.get("vars", {})
		if not bool(stall_res["pause_battery"]) and inst_vars.has("charge_left"):
			inst_vars["charge_left"] = maxf(0.0, float(inst_vars["charge_left"]) - dt)
		if not bool(stall_res["pause_durability"]) and inst_vars.has("durability_left"):
			inst_vars["durability_left"] = maxf(0.0, float(inst_vars["durability_left"]) - 1.0)
		_cleanup_destroyed_attachments(i)
		return {"broke": false, "damage_dealt": 0.0, "stalled": true, "stall_summary": stall_res}

	# Compute effective DPS with Wrong-Tool Penalty and Modifiers (Law L6)
	var mod_dps := rules.resolve_stat("base_dps", base_dps, active_insts, env)
	var penalty := compute_wrong_tool_penalty(tool_type_str, tool_tier_val, ideal_tool_str, req_tier_val)

	# Tectonic catch-up bonus on shallow tiles
	var pcts := compute_depth_percentiles()
	var tectonic_mult := 1.0
	if float(depth[i]) < float(pcts["p50"]) and (float(pcts["p90"]) - float(pcts["p10"])) >= 15.0:
		tectonic_mult += catalog.get_gmst_float("fTectonicCatchupSpeedBonus", 0.25)

	var effective_dps := (mod_dps * tectonic_mult) / (1.0 + penalty)

	# Enforce >= 1.0s minimum break pace on virgin blocks (unless already damaged)
	var min_break_sec := catalog.get_gmst_float("fMinBreakTimeSec", 1.0)
	var max_dps_for_pace := max_hp[i] / maxf(0.05, min_break_sec)
	var paced_dps := minf(effective_dps, max_dps_for_pace)
	var raw_dmg := paced_dps * dt
	var excess_overkill_dps := maxf(0.0, effective_dps - paced_dps) * dt

	# Apply incoming_damage modifiers (e.g. Thick Wool Carpet dampener)
	var final_dmg := rules.resolve_stat("incoming_damage", raw_dmg, active_insts, env)
	if final_dmg < raw_dmg:
		rules.dispatch_event("on_damage_absorbed", active_insts, env, self)

	damage_accum[i] += final_dmg
	rules.dispatch_event("on_damage_dealt", active_insts, env, self)

	# Multi-bucket fluid scooping check
	if is_fluid_active and tool_type_str == "BUCKET":
		var scoop_hp := catalog.get_gmst_float("fBucketScoopHp", 100.0)
		while damage_accum[i] >= scoop_hp and fluid_level[i] > 0:
			damage_accum[i] -= scoop_hp
			fluid_level[i] -= 1
			max_hp[i] = maxf(10.0, float(fluid_level[i]) * scoop_hp)
			var fl_item := "blocks/water_aquifer" if fluid_type[i] == FLUID_WATER else "blocks/lava_pocket"
			grant_inventory_item(fl_item, tier[i], 1, "backpack")
			if fluid_level[i] <= 0:
				fluid_type[i] = FLUID_NONE
				damage_accum[i] = 0.0
				var sub_st: Dictionary = catalog.capsules.get(blk_id, {}).get("stats", {})
				max_hp[i] = float(sub_st.get("base_hp", 10.0)) * pow(1.8, float(tier[i]))
				break
		_cleanup_destroyed_attachments(i)
		return {"broke": false, "damage_dealt": final_dmg, "fluid_scooped": true}

	# Check block break and Zero-Spillover Refresh Gate
	var broke := false
	if damage_accum[i] >= max_hp[i]:
		var overkill := (damage_accum[i] - max_hp[i]) + excess_overkill_dps
		# Hard-clamp damage_accum to 0.0 (Zero spillover into next z-layer!)
		damage_accum[i] = 0.0
		phase[i] = PHASE_REFRESH_GATE
		gate_timer[i] = catalog.get_gmst_float("fRefreshGateSec", 0.05)
		broke = true

		if overkill > 0.0:
			var ok_env := _build_env(x, y, tool_inst, is_direct_tap, false, overkill)
			rules.dispatch_event("on_overkill", active_insts, ok_env, self)

		# Deplete 1 durability on break
		var tv: Dictionary = tool_inst.get("vars", {})
		if tv.has("durability_left"):
			tv["durability_left"] = maxf(0.0, float(tv["durability_left"]) - 1.0)
			if float(tv["durability_left"]) <= 0.0:
				rules.dispatch_event("on_deplete", [tool_inst], env, self)

		_complete_block_break(x, y, tool_inst)

	_cleanup_destroyed_attachments(i)
	return {"broke": broke, "damage_dealt": final_dmg}


## Secondary damage from reactions (e.g. Cleave or Crude Shattering Tome). Never triggers recursive overkill.
func apply_secondary_damage(origin_x: int, origin_y: int, target_sel: String, amount: float, rng_host: Object) -> void:
	var coords := _resolve_target_coords(origin_x, origin_y, target_sel, rng_host)
	for pt in coords:
		var tx: int = pt.x
		var ty: int = pt.y
		if not in_bounds(tx, ty):
			continue
		var ti := idx_of(tx, ty)
		if phase[ti] == PHASE_REFRESH_GATE or fluid_level[ti] > 0:
			continue
		var blk_id := catalog.block_int_to_id[base_id[ti]]
		var blk_st: Dictionary = catalog.capsules.get(blk_id, {}).get("stats", {})
		if int(blk_st.get("strict_tool_lock", 0)) == 1:
			continue

		var dummy_tool := {"capsule_id": "", "vars": {}}
		var active_insts := _gather_active_instances(ti, dummy_tool)
		var env := _build_env(tx, ty, dummy_tool, false, true, 0.0)
		var final_dmg := rules.resolve_stat("incoming_damage", amount, active_insts, env)
		if final_dmg < amount:
			rules.dispatch_event("on_damage_absorbed", active_insts, env, self)
		damage_accum[ti] += final_dmg
		if damage_accum[ti] >= max_hp[ti]:
			damage_accum[ti] = 0.0
			phase[ti] = PHASE_REFRESH_GATE
			gate_timer[ti] = catalog.get_gmst_float("fRefreshGateSec", 0.05)
			_complete_block_break(tx, ty, dummy_tool)
		_cleanup_destroyed_attachments(ti)


## Advances refresh gate timers (50ms cooldowns) and stationed auto-tools.
func step_physics(dt: float) -> void:
	var n := cols * rows
	for y in rows:
		for x in cols:
			var i := idx_of(x, y)
			if phase[i] == PHASE_REFRESH_GATE:
				gate_timer[i] -= dt
				if gate_timer[i] <= 0.0:
					gate_timer[i] = 0.0
					phase[i] = PHASE_MINING

			# Tick any stationed auto-tools on this tile
			var atts: Array = tile_attachments[i]
			for inst in atts:
				if bool(inst.get("destroyed", false)):
					continue
				var cid := str(inst.get("capsule_id", ""))
				var cap: Dictionary = catalog.capsules.get(cid, {})
				if cap.get("tags", []).has("automine"):
					var iv: Dictionary = inst.get("vars", {})
					if iv.has("charge_left") and float(iv["charge_left"]) <= 0.0:
						inst["destroyed"] = true
						continue
					apply_mining_tick(x, y, inst, dt, false)
					if phase[i] == PHASE_MINING and iv.has("charge_left"):
						iv["charge_left"] = maxf(0.0, float(iv["charge_left"]) - dt)
						if float(iv["charge_left"]) <= 0.0:
							var env := _build_env(x, y, inst, false, false, 0.0)
							rules.dispatch_event("on_deplete", [inst], env, self)
			_cleanup_destroyed_attachments(i)
	rules.flush_deferred_queue(self, 500)


func _complete_block_break(x: int, y: int, tool_inst: Dictionary) -> void:
	var i := idx_of(x, y)
	var old_depth := depth[i]
	var was_virgin := (old_depth >= max_depth_reached[i])
	var broken_block_id := catalog.block_int_to_id[base_id[i]]
	var broken_tier := tier[i]

	# High-Water Mark Law (Debate #2 Lock): Only grant virgin ore & roll quests if depth >= max_depth_reached
	if was_virgin:
		var route := "paired_chest" if catalog.capsules.get(str(tool_inst.get("capsule_id", "")), {}).get("tags", []).has("automine") else "backpack"
		grant_inventory_item(broken_block_id, broken_tier, 1, route)
		player_grime += 1.0

	var new_z := old_depth + 1
	depth[i] = new_z
	if new_z > max_depth_reached[i]:
		max_depth_reached[i] = new_z
	if new_z > player_max_depth:
		player_max_depth = new_z

	if depth[i] < max_depth_reached[i]:
		# Exposed block is previously excavated Backfill Packed Earth
		base_id[i] = int(catalog.block_id_to_int.get("blocks/dirt", 0))
		tier[i] = 0
		max_hp[i] = 5.0
		fluid_type[i] = FLUID_NONE
		fluid_level[i] = 0
	else:
		var imb := compute_local_imbalance(x, y)
		_populate_tile_from_generator(x, y, new_z, imb)
		# 0.5% Lost Cat emergent quest injection on virgin layer reveal
		if quest_lost_cat_active and not _any_tile_has_cat():
			var cat_chance := catalog.get_gmst_float("fLostCatSpawnChance", 0.005)
			if rules.expr_host.roll(cat_chance) > 0.0:
				dynamic_entity_id[i] = ENTITY_LOST_CAT

	# Event-driven 4-neighbor cellular fluid siphon check
	_evaluate_fluid_siphon_around(x, y)


func _populate_tile_from_generator(x: int, y: int, z: int, local_imb: float) -> void:
	var i := idx_of(x, y)
	var v := generator.sample_voxel(x, y, z, local_imb, true)
	base_id[i] = int(v["solid_int"])
	tier[i] = int(v["tier"])
	var fl_str := str(v["fluid_type"])
	if fl_str == "WATER":
		fluid_type[i] = FLUID_WATER
		fluid_level[i] = int(v["fluid_level"])
		max_hp[i] = float(fluid_level[i]) * catalog.get_gmst_float("fBucketScoopHp", 100.0)
	elif fl_str == "LAVA":
		fluid_type[i] = FLUID_LAVA
		fluid_level[i] = int(v["fluid_level"])
		max_hp[i] = float(fluid_level[i]) * catalog.get_gmst_float("fBucketScoopHp", 100.0)
	else:
		fluid_type[i] = FLUID_NONE
		fluid_level[i] = 0
		max_hp[i] = float(v["max_hp"])


## Section 5.1: Event-Driven Downhill Fluid Siphon & Water+Lava -> Obsidian Reaction.
func _evaluate_fluid_siphon_around(cx: int, cy: int) -> void:
	# Check if neighbors drain into (cx, cy), OR if (cx, cy) has fluid and drains into a deeper neighbor
	_siphon_into_basin(cx, cy)
	for d in [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]:
		var nx: int = cx + d.x
		var ny: int = cy + d.y
		if in_bounds(nx, ny):
			_siphon_into_basin(nx, ny)


func _siphon_into_basin(bx: int, by: int) -> void:
	var bi := idx_of(bx, by)
	var bz := depth[bi]
	var max_buckets := catalog.get_gmst_int("fMaxFluidBucketsPerTile", 9)

	# Gather orthogonal neighbors with fluid_level > 0 at strictly shallower depth (z_neighbor < bz)
	var donors: Array[Dictionary] = []
	var dirs := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
	for d_idx in dirs.size():
		var nx: int = bx + dirs[d_idx].x
		var ny: int = by + dirs[d_idx].y
		if not in_bounds(nx, ny):
			continue
		var ni := idx_of(nx, ny)
		if fluid_level[ni] > 0 and fluid_type[ni] != FLUID_NONE and depth[ni] < bz:
			donors.append({"idx": ni, "z": depth[ni], "order": d_idx})

	if donors.is_empty():
		return

	# Sort shallowest first (highest gravitational head), then clockwise N, E, S, W
	donors.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["z"] != b["z"]:
			return int(a["z"]) < int(b["z"])
		return int(a["order"]) < int(b["order"])
	)

	for d_info in donors:
		var ni: int = d_info["idx"]
		var incoming_type := fluid_type[ni]
		var incoming_vol := fluid_level[ni]

		# Check Water + Lava -> Obsidian Hazard reaction
		if fluid_level[bi] > 0 and fluid_type[bi] != FLUID_NONE and fluid_type[bi] != incoming_type:
			# Transform basin into Obsidian Hazard!
			fluid_level[ni] = 0
			fluid_type[ni] = FLUID_NONE
			_restore_solid_hp_after_drain(ni)

			fluid_level[bi] = 0
			fluid_type[bi] = FLUID_NONE
			if catalog.block_id_to_int.has("blocks/obsidian_hazard"):
				base_id[bi] = int(catalog.block_id_to_int["blocks/obsidian_hazard"])
				var obs_st: Dictionary = catalog.capsules["blocks/obsidian_hazard"].get("stats", {})
				max_hp[bi] = float(obs_st.get("base_hp", 500.0))
				damage_accum[bi] = 0.0
			return

		# Volume-conserving downhill transfer
		var space_left := maxi(0, max_buckets - fluid_level[bi])
		if space_left <= 0:
			break
		var transferred := mini(incoming_vol, space_left)
		fluid_type[bi] = incoming_type
		fluid_level[bi] += transferred
		max_hp[bi] = float(fluid_level[bi]) * catalog.get_gmst_float("fBucketScoopHp", 100.0)

		fluid_level[ni] -= transferred
		if fluid_level[ni] <= 0:
			fluid_level[ni] = 0
			fluid_type[ni] = FLUID_NONE
			_restore_solid_hp_after_drain(ni)


func _restore_solid_hp_after_drain(tile_idx: int) -> void:
	damage_accum[tile_idx] = 0.0
	var bid_str := catalog.block_int_to_id[base_id[tile_idx]]
	var st: Dictionary = catalog.capsules.get(bid_str, {}).get("stats", {})
	max_hp[tile_idx] = float(st.get("base_hp", 10.0)) * pow(1.8, float(tier[tile_idx]))


## Section 5.2A: Backfill System (raises floor depth -= 1 using Dirt/Stone without duplicating ores).
func apply_backfill(x: int, y: int, material_id: String = "blocks/dirt") -> bool:
	if not in_bounds(x, y):
		return false
	var i := idx_of(x, y)
	if depth[i] <= 0:
		return false
	depth[i] -= 1
	damage_accum[i] = 0.0
	fluid_type[i] = FLUID_NONE
	fluid_level[i] = 0
	base_id[i] = int(catalog.block_id_to_int.get(material_id, 0))
	tier[i] = 0
	max_hp[i] = 5.0
	return true


## Section 5.2A: Connected-Component BFS Hazard Cluster & 8-Connected Exterior Perimeter Calculator.
func get_hazard_cluster_and_perimeter(start_x: int, start_y: int) -> Dictionary:
	if not in_bounds(start_x, start_y):
		return {"cluster": [], "perimeter": [], "ready_to_detonate": false}
	var start_i := idx_of(start_x, start_y)
	var target_base := base_id[start_i]
	var blk_id := catalog.block_int_to_id[target_base]
	var st: Dictionary = catalog.capsules.get(blk_id, {}).get("stats", {})
	if int(st.get("is_hazard", 0)) == 0:
		return {"cluster": [], "perimeter": [], "ready_to_detonate": false}

	var cluster: Array[Vector2i] = []
	var cluster_set: Dictionary = {}
	var queue: Array[Vector2i] = [Vector2i(start_x, start_y)]
	cluster_set[Vector2i(start_x, start_y)] = true

	# 4-connected BFS to group adjacent Hazards of the same type
	while not queue.is_empty():
		var cur: Vector2i = queue.pop_front()
		cluster.append(cur)
		for d in [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]:
			var nx: int = cur.x + d.x
			var ny: int = cur.y + d.y
			var npt := Vector2i(nx, ny)
			if in_bounds(nx, ny) and not cluster_set.has(npt):
				var ni := idx_of(nx, ny)
				if base_id[ni] == target_base:
					cluster_set[npt] = true
					queue.append(npt)

	# Collect 8-connected in-bounds exterior perimeter (3 corner, 5 edge, 8 single interior, 10 merged pair)
	var perim_map: Dictionary = {}
	for hpt in cluster:
		var hz := depth[idx_of(hpt.x, hpt.y)]
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				if dx == 0 and dy == 0:
					continue
				var px: int = hpt.x + dx
				var py: int = hpt.y + dy
				var ppt := Vector2i(px, py)
				if in_bounds(px, py) and not cluster_set.has(ppt):
					perim_map[ppt] = hz

	var perimeter: Array[Vector2i] = []
	var req_tier := int(st.get("required_catalyst_tier", 0))
	var all_satisfied := not perim_map.is_empty()

	for ppt in perim_map.keys():
		perimeter.append(ppt)
		var pi := idx_of(ppt.x, ppt.y)
		var req_z: int = perim_map[ppt]
		# Equal-depth requirement + Asymmetric downward catalyst tier inheritance (catalyst_tier >= req_tier)
		if depth[pi] != req_z or placed_catalyst_id[pi] < 0 or placed_catalyst_tier[pi] < req_tier:
			all_satisfied = false

	return {
		"cluster": cluster,
		"perimeter": perimeter,
		"perimeter_count": perimeter.size(),
		"ready_to_detonate": all_satisfied
	}


func place_catalyst_on_tile(x: int, y: int, catalyst_block_id: String, catalyst_tier_val: int) -> bool:
	if not in_bounds(x, y):
		return false
	var i := idx_of(x, y)
	placed_catalyst_id[i] = int(catalog.block_id_to_int.get(catalyst_block_id, 0))
	placed_catalyst_tier[i] = catalyst_tier_val
	return true


func try_detonate_hazard_at(x: int, y: int) -> Dictionary:
	var info := get_hazard_cluster_and_perimeter(x, y)
	if not bool(info["ready_to_detonate"]):
		return {"detonated": false, "perimeter_count": info.get("perimeter_count", 0)}

	var cluster: Array = info["cluster"]
	var perimeter: Array = info["perimeter"]

	# Consume perimeter catalysts and auto-clear any PACKED_BACKFILL scaffolding down to max_depth_reached!
	for ppt in perimeter:
		var pi := idx_of(ppt.x, ppt.y)
		placed_catalyst_id[pi] = -1
		placed_catalyst_tier[pi] = 0
		if depth[pi] < max_depth_reached[pi]:
			depth[pi] = max_depth_reached[pi]
			_populate_tile_from_generator(ppt.x, ppt.y, depth[pi], 0.0)

	# Shatter all hazard blocks in the connected cluster and award loot
	for hpt in cluster:
		var hi := idx_of(hpt.x, hpt.y)
		var h_id := catalog.block_int_to_id[base_id[hi]]
		grant_inventory_item(h_id, tier[hi], 2, "backpack")
		depth[hi] += 1
		if depth[hi] > max_depth_reached[hi]:
			max_depth_reached[hi] = depth[hi]
		_populate_tile_from_generator(hpt.x, hpt.y, depth[hi], 0.0)

	return {"detonated": true, "shattered_count": cluster.size(), "perimeter_count": perimeter.size()}


## Section 7.2: Safe Drunk Touch Drift Coordinate Offset
func apply_drunk_touch_offset(touch_px: Vector2, time_sec: float) -> Vector2:
	var amp := float(rules.shared_registers.get("active_drunk_drift_px", 0.0))
	if amp <= 0.0:
		return touch_px
	var dx := sin(1.7 * time_sec + cos(0.8 * time_sec))
	var dy := cos(1.3 * time_sec + sin(1.1 * time_sec))
	return touch_px + Vector2(dx, dy) * amp


func grant_inventory_item(item_id: String, item_tier: int, qty: int, route: String = "backpack") -> void:
	if qty <= 0:
		return
	var key := "%s:%d" % [item_id, item_tier]
	if route == "paired_chest":
		paired_chest_loot[key] = int(paired_chest_loot.get(key, 0)) + qty
	else:
		inventory[key] = int(inventory.get(key, 0)) + qty


## Section 3.3B: Asymmetric Downward Recipe Inheritance (item_tier >= req_tier satisfies requirement).
func can_satisfy_requirement(req_base_id: String, req_tier: int, req_qty: int) -> bool:
	var found := 0
	var prefix := req_base_id + ":"
	for k in inventory.keys():
		if str(k).begins_with(prefix):
			var t_val := int(str(k).split(":")[1])
			if t_val >= req_tier:
				found += int(inventory[k])
				if found >= req_qty:
					return true
	return false


func _gather_active_instances(tile_idx: int, tool_inst: Dictionary) -> Array:
	var out: Array = []
	if not tool_inst.is_empty() and str(tool_inst.get("capsule_id", "")) != "":
		tool_inst["is_covering_current_tile"] = false
		out.append(tool_inst)
	for eq in player_equipped_items:
		if not bool(eq.get("destroyed", false)):
			eq["is_covering_current_tile"] = false
			out.append(eq)
	for att in tile_attachments[tile_idx]:
		if not bool(att.get("destroyed", false)):
			att["is_covering_current_tile"] = true
			out.append(att)
	return out


func _build_env(x: int, y: int, tool_inst: Dictionary, is_direct_tap: bool, is_secondary: bool, overkill: float) -> Dictionary:
	var i := idx_of(x, y)
	var blk_id := catalog.block_int_to_id[base_id[i]]
	var blk_st: Dictionary = catalog.capsules.get(blk_id, {}).get("stats", {})
	var tv: Dictionary = tool_inst.get("vars", {})
	return {
		"tile": {
			"x": float(x),
			"y": float(y),
			"depth": float(depth[i]),
			"max_depth_reached": float(max_depth_reached[i]),
			"tier": float(tier[i]),
			"hp": maxf(0.0, max_hp[i] - damage_accum[i]),
			"max_hp": max_hp[i],
			"fluid_level": float(fluid_level[i]),
			"is_hazard": float(blk_st.get("is_hazard", 0)),
			"is_strict_locked": 1.0 if (fluid_level[i] > 0 or int(blk_st.get("strict_tool_lock", 0)) == 1) else 0.0,
			"covered_by_self": 0.0
		},
		"player": {
			"max_depth": float(player_max_depth),
			"grime": player_grime,
			"is_rested": 1.0 if player_is_rested else 0.0,
			"drunk_seconds": 0.0
		},
		"tool": {
			"tier": float(catalog.capsules.get(str(tool_inst.get("capsule_id", "")), {}).get("stats", {}).get("tool_tier", 0)),
			"dps": float(catalog.capsules.get(str(tool_inst.get("capsule_id", "")), {}).get("stats", {}).get("base_dps", 10.0)),
			"charge_left": float(tv.get("charge_left", 0.0)),
			"durability_left": float(tv.get("durability_left", 0.0)),
			"overkill_damage": overkill
		},
		"ctx": {
			"dt": 0.016,
			"now": float(Time.get_ticks_msec()) * 0.001,
			"is_direct_tap": 1.0 if is_direct_tap else 0.0,
			"is_secondary_damage": 1.0 if is_secondary else 0.0
		}
	}


func _resolve_target_coords(ox: int, oy: int, sel: String, rng_host: Object) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if sel == "self_tile":
		out.append(Vector2i(ox, oy))
	elif sel == "neighbors_4" or sel == "random_neighbor_4" or sel == "shallowest_neighbor_4":
		for d in [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]:
			if in_bounds(ox + d.x, oy + d.y):
				out.append(Vector2i(ox + d.x, oy + d.y))
		if sel == "random_neighbor_4" and not out.is_empty():
			var pick_idx := int(rng_host.call("roll", 0.5)) % out.size()
			return [out[pick_idx]]
		elif sel == "shallowest_neighbor_4" and not out.is_empty():
			out.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
				return depth[idx_of(a.x, a.y)] < depth[idx_of(b.x, b.y)]
			)
			return [out[0]]
	elif sel == "neighbors_8":
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				if (dx != 0 or dy != 0) and in_bounds(ox + dx, oy + dy):
					out.append(Vector2i(ox + dx, oy + dy))
	elif sel == "row":
		for xx in cols:
			out.append(Vector2i(xx, oy))
	elif sel == "column":
		for yy in rows:
			out.append(Vector2i(ox, yy))
	return out


func _any_tile_has_cat() -> bool:
	for i in dynamic_entity_id.size():
		if dynamic_entity_id[i] == ENTITY_LOST_CAT:
			return true
	return false


func _jump_lost_cat_from(ox: int, oy: int) -> void:
	var rad := catalog.get_gmst_int("fLostCatJumpRadius", 2)
	var candidates: Array[Vector2i] = []
	for dy in range(-rad, rad + 1):
		for dx in range(-rad, rad + 1):
			if dx == 0 and dy == 0:
				continue
			var nx := ox + dx
			var ny := oy + dy
			if in_bounds(nx, ny):
				var ni := idx_of(nx, ny)
				if fluid_level[ni] == 0:
					candidates.append(Vector2i(nx, ny))
	if not candidates.is_empty():
		var pick := candidates[0]
		dynamic_entity_id[idx_of(pick.x, pick.y)] = ENTITY_LOST_CAT


func _cleanup_destroyed_attachments(tile_idx: int) -> void:
	var arr: Array = tile_attachments[tile_idx]
	for k in range(arr.size() - 1, -1, -1):
		if bool(arr[k].get("destroyed", false)):
			arr.remove_at(k)
