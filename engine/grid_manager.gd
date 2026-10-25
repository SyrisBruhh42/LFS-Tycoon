class_name GridManager
extends RefCounted
## Contiguous SoA Quarry State Engine, DPI Integer Scaler (D1 Freeze & Pan),
## Persistent HP + 50ms Zero-Spillover Gate, Event-Driven Cellular Fluids & BFS Connected Hazards.
##
## Vocabulary wiring contract: every event in vocab/events.json is fired here via `rules.dispatch_event("<event>"`
## and every modifiable stat is read via `rules.resolve_stat("<stat>"`. tools/check_capsules.py fails G1 when a
## vocab entry has no call site, so the vocabulary can never again promise behaviour the engine does not deliver.

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
var tile_block_inst: Array = []            # per-tile live instance of the exposed block capsule ({} unless it has rules)
var tile_biome_id: PackedStringArray = PackedStringArray()
var biome_insts: Dictionary = {}           # biome_id -> shared live instance (only for biomes with rules)
var player_tool: Dictionary = {}           # the tool the player holds; socketed devices live in player_tool["sockets"]
var player_equipped_items: Array = []      # Array[Dictionary] (consumed buffs, read books/perks; active until destroy_self)
var player_owned_capsules: Array = []      # Array[Dictionary] (purchased/owned tools, devices, consumables, books in player stash)
var inventory: Dictionary = {}             # "capsule_id:tier" -> int count
var paired_chest_loot: Dictionary = {}     # "capsule_id:tier" -> int count
var ground_pile: Dictionary = {}           # "capsule_id:tier" -> int count
var next_instance_uid: int = 1
var _second_accum: float = 0.0

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
	tile_block_inst.resize(n)
	tile_biome_id.resize(n)
	for i in n:
		tile_attachments[i] = []
		tile_block_inst[i] = {}


func reset_quarry() -> void:
	biome_insts.clear()
	for cid in catalog.capsules.keys():
		var cap: Dictionary = catalog.capsules[cid]
		var aff: Array = cap.get("affordances", [])
		if aff.has("biome_profile") and (not cap.get("modifiers", []).is_empty() or not cap.get("reactions", []).is_empty()):
			biome_insts[str(cid)] = create_capsule_instance(str(cid))
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
			tile_block_inst[i] = {}
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
	rules.dispatch_event("on_hold_tick", active_insts, env, self)

	# Check strict tool lock (e.g. hitting Water or Obsidian with a Pickaxe deals 0 damage)
	if strict_locked and tool_type_str != ideal_tool_str:
		var stall_res := rules.dispatch_event("on_zero_damage_stall", active_insts, env, self)
		if not bool(stall_res["pause_battery"]):
			var bat_mult := clampf(rules.resolve_stat("battery_drain_mult", 1.0, active_insts, env), 0.0, 10.0)
			if _drain_charge(tool_inst, dt * bat_mult):
				rules.dispatch_event("on_deplete", [tool_inst], env, self)
		if not bool(stall_res["pause_durability"]):
			# Stalled wear is per second of stalling (frame-rate independent), scaled by durability_drain_mult.
			_wear_tool(tool_inst, dt * _durability_mult(active_insts, env), env)
		_cleanup_destroyed_attachments(i)
		return {"broke": false, "damage_dealt": 0.0, "stalled": true, "stall_summary": stall_res}

	# Compute effective DPS with Wrong-Tool Penalty and Modifiers (Law L6)
	var mod_dps := rules.resolve_stat("base_dps", base_dps, active_insts, env)
	var base_penalty := compute_wrong_tool_penalty(tool_type_str, tool_tier_val, ideal_tool_str, req_tier_val)
	var penalty := maxf(0.0, rules.resolve_stat("wrong_tool_penalty", base_penalty, active_insts, env))
	var break_mult := clampf(rules.resolve_stat("break_time_mult", 1.0, active_insts, env), 0.25, 10.0)

	# Tectonic catch-up bonus on shallow tiles
	var pcts := compute_depth_percentiles()
	var tectonic_mult := 1.0
	if float(depth[i]) < float(pcts["p50"]) and (float(pcts["p90"]) - float(pcts["p10"])) >= 15.0:
		tectonic_mult += catalog.get_gmst_float("fTectonicCatchupSpeedBonus", 0.25)

	var effective_dps := (mod_dps * tectonic_mult) / (1.0 + penalty) / break_mult

	# Enforce >= 1.0s minimum break pace on virgin blocks (unless already damaged).
	# break_time_mult can lengthen the minimum but never shorten it: mining is never instant.
	var min_break_sec := catalog.get_gmst_float("fMinBreakTimeSec", 1.0) * maxf(1.0, break_mult)
	var max_dps_for_pace := max_hp[i] / maxf(0.05, min_break_sec)
	var paced_dps := minf(effective_dps, max_dps_for_pace)
	var raw_dmg := maxf(0.0, paced_dps * dt)
	var excess_overkill_dps := maxf(0.0, effective_dps - paced_dps) * dt
	rules.dispatch_event("on_damage_calc", active_insts, env, self)

	# Apply incoming_damage modifiers (e.g. Thick Wool Carpet dampener). Damage never heals a tile.
	var final_dmg := maxf(0.0, rules.resolve_stat("incoming_damage", raw_dmg, active_insts, env))
	if final_dmg < raw_dmg:
		rules.dispatch_event("on_damage_absorbed", active_insts, env, self)

	damage_accum[i] += final_dmg
	if not is_fluid_active:
		_apply_min_hp_clamp(i, active_insts, env)
	if final_dmg > 0.0:
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
			# Engine cleave: cleave_pct of the overkill splashes to neighbours (cleave_radius >= 2 -> 8 neighbours).
			var cleave := clampf(rules.resolve_stat("cleave_pct", 0.0, active_insts, ok_env), 0.0, 1.0)
			if cleave > 0.0:
				var radius := rules.resolve_stat("cleave_radius", 1.0, active_insts, ok_env)
				apply_secondary_damage(x, y, "neighbors_8" if radius >= 2.0 else "neighbors_4", overkill * cleave, rules.expr_host)

		# Deplete 1 durability on break, scaled by durability_drain_mult (negative values repair).
		_wear_tool(tool_inst, _durability_mult(active_insts, env), env)

		_complete_block_break(x, y, tool_inst, is_direct_tap, false)

	_cleanup_destroyed_attachments(i)
	return {"broke": broke, "damage_dealt": final_dmg}


func _durability_mult(active_insts: Array, env: Dictionary) -> float:
	return clampf(rules.resolve_stat("durability_drain_mult", 1.0, active_insts, env), -3.0, 10.0)


## Engine-owned durability: subtracts `amount` (negative repairs), capped to [0, durability_max].
## Fires on_deplete exactly once when durability crosses to zero.
func _wear_tool(tool_inst: Dictionary, amount: float, env: Dictionary) -> void:
	var tv: Dictionary = tool_inst.get("vars", {})
	if not tv.has("durability_left"):
		return
	var before := float(tv["durability_left"])
	var st: Dictionary = catalog.capsules.get(str(tool_inst.get("capsule_id", "")), {}).get("stats", {})
	var cap := maxf(before, float(st.get("durability_max", before)))
	var after := clampf(before - amount, 0.0, cap)
	tv["durability_left"] = after
	if before > 0.0 and after <= 0.0:
		rules.dispatch_event("on_deplete", [tool_inst], env, self)


## Engine-owned charge: subtracts `amount` seconds, capped to [0, charge_max_sec]. Returns true when it hits zero.
func _drain_charge(tool_inst: Dictionary, amount: float) -> bool:
	var tv: Dictionary = tool_inst.get("vars", {})
	if not tv.has("charge_left"):
		return false
	var before := float(tv["charge_left"])
	var st: Dictionary = catalog.capsules.get(str(tool_inst.get("capsule_id", "")), {}).get("stats", {})
	var cap := maxf(before, float(st.get("charge_max_sec", before)))
	var after := clampf(before - amount, 0.0, cap)
	tv["charge_left"] = after
	return before > 0.0 and after <= 0.0


## min_hp_clamp: the tile's remaining HP can never be pushed below the resolved value (protective covers).
func _apply_min_hp_clamp(tile_idx: int, active_insts: Array, env: Dictionary) -> void:
	var floor_hp := clampf(rules.resolve_stat("min_hp_clamp", 0.0, active_insts, env), 0.0, max_hp[tile_idx])
	if floor_hp > 0.0:
		damage_accum[tile_idx] = minf(damage_accum[tile_idx], max_hp[tile_idx] - floor_hp)


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
		var final_dmg := maxf(0.0, rules.resolve_stat("incoming_damage", amount, active_insts, env))
		if final_dmg < amount:
			rules.dispatch_event("on_damage_absorbed", active_insts, env, self)
		damage_accum[ti] += final_dmg
		_apply_min_hp_clamp(ti, active_insts, env)
		if final_dmg > 0.0:
			rules.dispatch_event("on_damage_dealt", active_insts, env, self)
		if damage_accum[ti] >= max_hp[ti]:
			damage_accum[ti] = 0.0
			phase[ti] = PHASE_REFRESH_GATE
			gate_timer[ti] = catalog.get_gmst_float("fRefreshGateSec", 0.05)
			_complete_block_break(tx, ty, dummy_tool, false, true)
		_cleanup_destroyed_attachments(ti)


## Advances refresh gate timers (50ms cooldowns), stationed auto-tools, and fires on_second_tick once per second.
func step_physics(dt: float) -> void:
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
					var tick_res := apply_mining_tick(x, y, inst, dt, false)
					# Stalled ticks already drained (or paused) charge inside apply_mining_tick.
					if phase[i] == PHASE_MINING and iv.has("charge_left") and not bool(tick_res.get("stalled", false)):
						var act := _gather_active_instances(i, inst)
						var env := _build_env(x, y, inst, false, false, 0.0)
						var bat_mult := clampf(rules.resolve_stat("battery_drain_mult", 1.0, act, env), 0.0, 10.0)
						if _drain_charge(inst, dt * bat_mult):
							rules.dispatch_event("on_deplete", [inst], env, self)
			_cleanup_destroyed_attachments(i)

	_second_accum += dt
	var seconds_fired := 0
	while _second_accum >= 1.0 and seconds_fired < 60:
		_second_accum -= 1.0
		seconds_fired += 1
		_dispatch_second_tick()
	if seconds_fired >= 60:
		_second_accum = 0.0  # Long gaps are the offline simulator's job, not a 60+ event burst.
	rules.flush_deferred_queue(self, 500)


## on_second_tick reaches every live instance exactly once: player-level (held tool, its sockets, consumed buffs),
## each tile's attachments (+ their sockets) and reactive block, and each reactive biome.
func _dispatch_second_tick() -> void:
	var p_insts := _player_instances()
	if not p_insts.is_empty():
		rules.dispatch_event("on_second_tick", p_insts, _build_env_neutral(player_tool), self)
	for y in rows:
		for x in cols:
			var i := idx_of(x, y)
			var list: Array = []
			var worker: Dictionary = {}
			for att in tile_attachments[i]:
				if bool(att.get("destroyed", false)):
					continue
				att["is_covering_current_tile"] = true
				list.append(att)
				if worker.is_empty() and catalog.capsules.get(str(att.get("capsule_id", "")), {}).get("tags", []).has("automine"):
					worker = att
				for s in att.get("sockets", []):
					if not bool(s.get("destroyed", false)):
						s["is_covering_current_tile"] = false
						list.append(s)
			var bi: Dictionary = _block_inst_at(i)
			if not bi.is_empty() and not bool(bi.get("destroyed", false)):
				bi["is_covering_current_tile"] = true
				list.append(bi)
			if not list.is_empty():
				rules.dispatch_event("on_second_tick", list, _build_env(x, y, worker, false, false, 0.0), self)
				_cleanup_destroyed_attachments(i)
	for b_id in biome_insts.keys():
		var b_inst: Dictionary = biome_insts[b_id]
		if not bool(b_inst.get("destroyed", false)):
			rules.dispatch_event("on_second_tick", [b_inst], _build_env_neutral({}), self)
	_prune_player_items()


func _complete_block_break(x: int, y: int, tool_inst: Dictionary, is_direct_tap: bool = false, is_secondary: bool = false) -> void:
	var i := idx_of(x, y)
	var old_depth := depth[i]
	var was_virgin := (old_depth >= max_depth_reached[i])
	var broken_block_id := catalog.block_int_to_id[base_id[i]]
	var broken_tier := tier[i]
	# Capture the broken layer's context (including its block instance) before the tile changes.
	var broken_insts := _gather_active_instances(i, tool_inst)
	var broken_env := _build_env(x, y, tool_inst, is_direct_tap, is_secondary, 0.0)

	# High-Water Mark Law (Debate #2 Lock): Only grant virgin ore & roll quests if depth >= max_depth_reached
	if was_virgin:
		var route := "paired_chest" if catalog.capsules.get(str(tool_inst.get("capsule_id", "")), {}).get("tags", []).has("automine") else "backpack"
		if route == "backpack":
			var chest_pct := clampf(rules.resolve_stat("chest_route_pct", 0.0, broken_insts, broken_env), 0.0, 1.0)
			if chest_pct > 0.0 and rules.expr_host.roll(chest_pct) > 0.0:
				route = "paired_chest"
		# yield_mult scales the drop count (fraction rolled); luck_mult - 1 is the chance of a +1 tier drop.
		var y_mult := clampf(rules.resolve_stat("yield_mult", 1.0, broken_insts, broken_env), 0.0, 10.0)
		var qty := int(floor(y_mult))
		var frac := y_mult - float(qty)
		if frac > 0.0 and rules.expr_host.roll(frac) > 0.0:
			qty += 1
		var luck := clampf(rules.resolve_stat("luck_mult", 1.0, broken_insts, broken_env) - 1.0, 0.0, 1.0)
		var drop_tier := broken_tier
		if luck > 0.0 and rules.expr_host.roll(luck) > 0.0:
			drop_tier += 1
		grant_inventory_item(broken_block_id, drop_tier, qty, route)
		var grime_mult := maxf(0.0, rules.resolve_stat("grime_gain_mult", 1.0, broken_insts, broken_env))
		player_grime += 1.0 * grime_mult

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
		tile_block_inst[i] = {}
	else:
		var imb := compute_local_imbalance(x, y)
		_populate_tile_from_generator(x, y, new_z, imb)
		# 0.5% Lost Cat emergent quest injection on virgin layer reveal (+ cat_lure_bonus)
		if quest_lost_cat_active and not _any_tile_has_cat():
			var cat_chance := catalog.get_gmst_float("fLostCatSpawnChance", 0.005)
			var cat_bonus := maxf(0.0, rules.resolve_stat("cat_lure_bonus", 0.0, broken_insts, broken_env))
			if rules.expr_host.roll(clampf(cat_chance + cat_bonus, 0.0, 1.0)) > 0.0:
				dynamic_entity_id[i] = ENTITY_LOST_CAT

	# Event-driven 4-neighbor cellular fluid siphon check
	_evaluate_fluid_siphon_around(x, y)

	rules.dispatch_event("on_block_break", broken_insts, broken_env, self)
	var new_insts := _gather_active_instances(i, tool_inst)
	var new_env := _build_env(x, y, tool_inst, is_direct_tap, is_secondary, 0.0)
	rules.dispatch_event("on_layer_reveal", new_insts, new_env, self)
	if int(new_env["tile"]["is_hazard"]) == 1:
		rules.dispatch_event("on_hazard_expose", new_insts, new_env, self)


func _populate_tile_from_generator(x: int, y: int, z: int, local_imb: float) -> void:
	var i := idx_of(x, y)
	var v := generator.sample_voxel(x, y, z, local_imb, true)
	base_id[i] = int(v["solid_int"])
	tier[i] = int(v["tier"])
	tile_biome_id[i] = str(v.get("biome_id", ""))
	tile_block_inst[i] = {}
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

	var any_flow := false
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
				tile_block_inst[bi] = {}
			var no_tool := {"capsule_id": "", "vars": {}}
			rules.dispatch_event("on_fluid_contact", _gather_active_instances(bi, no_tool), _build_env(bx, by, no_tool, false, false, 0.0), self)
			return

		# Volume-conserving downhill transfer
		var space_left := maxi(0, max_buckets - fluid_level[bi])
		if space_left <= 0:
			break
		var transferred := mini(incoming_vol, space_left)
		fluid_type[bi] = incoming_type
		fluid_level[bi] += transferred
		max_hp[bi] = float(fluid_level[bi]) * catalog.get_gmst_float("fBucketScoopHp", 100.0)
		any_flow = any_flow or transferred > 0

		fluid_level[ni] -= transferred
		if fluid_level[ni] <= 0:
			fluid_level[ni] = 0
			fluid_type[ni] = FLUID_NONE
			_restore_solid_hp_after_drain(ni)

	if any_flow:
		var flow_tool := {"capsule_id": "", "vars": {}}
		rules.dispatch_event("on_fluid_flow", _gather_active_instances(bi, flow_tool), _build_env(bx, by, flow_tool, false, false, 0.0), self)


func _restore_solid_hp_after_drain(tile_idx: int) -> void:
	damage_accum[tile_idx] = 0.0
	var bid_str := catalog.block_int_to_id[base_id[tile_idx]]
	var st: Dictionary = catalog.capsules.get(bid_str, {}).get("stats", {})
	max_hp[tile_idx] = float(st.get("base_hp", 10.0)) * pow(1.8, float(tier[tile_idx]))


## Section 5.2A: Backfill System (raises floor depth -= 1 using Dirt/Stone without duplicating ores).
## Player-initiated backfill fires on_backfill; reaction-driven raises (modify_depth) do not, so they cannot recurse.
func apply_backfill(x: int, y: int, material_id: String = "blocks/dirt") -> bool:
	if not in_bounds(x, y):
		return false
	var i := idx_of(x, y)
	if not _raise_floor(i, material_id):
		return false
	rules.dispatch_event("on_backfill", _gather_active_instances(i, player_tool), _build_env(x, y, player_tool, true, false, 0.0), self)
	return true


func _raise_floor(i: int, material_id: String) -> bool:
	if depth[i] <= 0:
		return false
	depth[i] -= 1
	damage_accum[i] = 0.0
	fluid_type[i] = FLUID_NONE
	fluid_level[i] = 0
	base_id[i] = int(catalog.block_id_to_int.get(material_id, 0))
	tier[i] = 0
	max_hp[i] = 5.0
	tile_block_inst[i] = {}
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
		var det_insts := _gather_active_instances(hi, player_tool)
		var det_env := _build_env(hpt.x, hpt.y, player_tool, true, false, 0.0)
		grant_inventory_item(h_id, tier[hi], 2, "backpack")
		depth[hi] += 1
		if depth[hi] > max_depth_reached[hi]:
			max_depth_reached[hi] = depth[hi]
		_populate_tile_from_generator(hpt.x, hpt.y, depth[hi], 0.0)
		rules.dispatch_event("on_hazard_detonate", det_insts, det_env, self)
		var rev_insts := _gather_active_instances(hi, player_tool)
		var rev_env := _build_env(hpt.x, hpt.y, player_tool, true, false, 0.0)
		rules.dispatch_event("on_layer_reveal", rev_insts, rev_env, self)
		if int(rev_env["tile"]["is_hazard"]) == 1:
			rules.dispatch_event("on_hazard_expose", rev_insts, rev_env, self)

	return {"detonated": true, "shattered_count": cluster.size(), "perimeter_count": perimeter.size()}


## Section 7.2: Safe Drunk Touch Drift Coordinate Offset
func apply_drunk_touch_offset(touch_px: Vector2, time_sec: float) -> Vector2:
	var base_amp := float(rules.shared_registers.get("active_drunk_drift_px", 0.0))
	var amp := maxf(0.0, rules.resolve_stat("drunk_drift_px", base_amp, _player_instances(), _build_env_neutral(player_tool)))
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
	elif route == "ground_pile":
		ground_pile[key] = int(ground_pile.get(key, 0)) + qty
	else:
		inventory[key] = int(inventory.get(key, 0)) + qty
		if catalog != null and catalog.capsules.has(item_id):
			var affs: Array = catalog.capsules[item_id].get("affordances", [])
			if not affs.has("mineable_block") and not affs.has("biome_profile") and not affs.has("npc_vendor"):
				var spawn_cap := mini(qty, 3)
				for _i in spawn_cap:
					player_owned_capsules.append(create_capsule_instance(item_id))


## Returns total owned count of req_base_id across backpack stacks (tier >= req_tier) and player_owned_capsules.
func get_owned_count(req_base_id: String, req_tier: int = 0) -> int:
	var found := 0
	var prefix := req_base_id + ":"
	for k in inventory.keys():
		if str(k).begins_with(prefix):
			var t_val := int(str(k).split(":")[1])
			if t_val >= req_tier:
				found += int(inventory[k])
	for inst in player_owned_capsules:
		if not bool(inst.get("destroyed", false)) and str(inst.get("capsule_id", "")) == req_base_id:
			found += 1
	return found


## Section 3.3B: Asymmetric Downward Recipe Inheritance (item_tier >= req_tier or owned capsule instance satisfies requirement).
func can_satisfy_requirement(req_base_id: String, req_tier: int, req_qty: int) -> bool:
	return get_owned_count(req_base_id, req_tier) >= req_qty


## Discrete player tap on tile (fires on_tap before hold mining).
func tap_tile(x: int, y: int, tool_inst: Dictionary) -> void:
	if not in_bounds(x, y):
		return
	if not tool_inst.is_empty():
		player_tool = tool_inst
	var i := idx_of(x, y)
	rules.dispatch_event("on_tap", _gather_active_instances(i, tool_inst), _build_env(x, y, tool_inst, true, false, 0.0), self)
	_cleanup_destroyed_attachments(i)


## Equip/unequip player tool or accessory, firing on_unequip / on_equip.
func equip_tool_instance(tool_inst: Dictionary) -> void:
	if not player_tool.is_empty() and str(player_tool.get("capsule_id", "")) != "":
		rules.dispatch_event("on_unequip", [player_tool], _build_env_neutral(player_tool), self)
	player_tool = tool_inst
	if not player_tool.is_empty() and str(player_tool.get("capsule_id", "")) != "":
		rules.dispatch_event("on_equip", [player_tool], _build_env_neutral(player_tool), self)


func equip_item(inst: Dictionary) -> void:
	if inst.is_empty():
		return
	player_equipped_items.append(inst)
	rules.dispatch_event("on_equip", [inst], _build_env_neutral(player_tool), self)


func unequip_item(inst: Dictionary) -> void:
	var idx := player_equipped_items.find(inst)
	if idx >= 0:
		player_equipped_items.remove_at(idx)
		rules.dispatch_event("on_unequip", [inst], _build_env_neutral(player_tool), self)


## Consume a consumable/book capsule instance, firing on_consume (and equipping temporary buff if not destroyed).
func consume_capsule(inst: Dictionary) -> bool:
	if inst.is_empty():
		return false
	var cid := str(inst.get("capsule_id", ""))
	var cap: Dictionary = catalog.capsules.get(cid, {})
	var aff: Array = cap.get("affordances", [])
	if not aff.has("consume") and not aff.has("read_book"):
		return false
	var env := _build_env_neutral(player_tool)
	var list := _player_instances()
	if not list.has(inst):
		list.push_front(inst)
	rules.dispatch_event("on_consume", list, env, self)
	if not bool(inst.get("destroyed", false)) and not player_equipped_items.has(inst):
		var mods: Array = cap.get("modifiers", [])
		var has_ongoing: bool = not mods.is_empty()
		if not has_ongoing:
			for r in cap.get("reactions", []):
				if str(r.get("when", "")) != "on_consume":
					has_ongoing = true
					break
		if has_ongoing:
			player_equipped_items.append(inst)
	_prune_player_items()
	return true


## Player hub / house / wash / market lifecycle hooks.
func enter_house() -> void:
	rules.dispatch_event("on_enter_house", _player_instances(), _build_env_neutral(player_tool), self)
	_prune_player_items()


func sleep_in_house() -> void:
	player_is_rested = true
	rules.dispatch_event("on_sleep", _player_instances(), _build_env_neutral(player_tool), self)
	_prune_player_items()


func wash_grime() -> void:
	player_grime = 0.0
	rules.dispatch_event("on_wash", _player_instances(), _build_env_neutral(player_tool), self)
	_prune_player_items()


func sell_to_market(item_id: String, item_tier: int, qty: int) -> int:
	if qty <= 0:
		return 0
	var key := "%s:%d" % [item_id, item_tier]
	var have := int(inventory.get(key, 0))
	var sold := mini(have, qty)
	if sold <= 0:
		return 0
	inventory[key] = have - sold
	if int(inventory[key]) <= 0:
		inventory.erase(key)
	var st: Dictionary = catalog.capsules.get(item_id, {}).get("stats", {})
	var unit_val := int(max(1, int(st.get("value_base", 1)) * int(pow(2.0, float(item_tier)))))
	var insts := _player_instances()
	var env := _build_env_neutral(player_tool)
	var val_mult := maxf(0.0, rules.resolve_stat("market_value_mult", 1.0, insts, env))
	var gold := int(round(float(sold * unit_val) * val_mult))
	rules.shared_registers["gold_earned_total"] = float(rules.shared_registers.get("gold_earned_total", 0.0)) + float(gold)
	rules.dispatch_event("on_market_sell", insts, env, self)
	_prune_player_items()
	return gold


func get_vendor_unlock_depth(vendor_capsule_id: String) -> int:
	var st: Dictionary = catalog.capsules.get(vendor_capsule_id, {}).get("stats", {})
	var base_unlock := float(st.get("unlock_depth", 0))
	var disc := rules.resolve_stat("vendor_depth_discount", 0.0, _player_instances(), _build_env_neutral(player_tool))
	return maxi(0, int(round(base_unlock - disc)))


## Returns true if item_id is a permanent Skill Bracket, Guild Mastery, Homestead Station, or Achievement Relic
## that gates recipes in offered_by[].price without being destroyed when a recipe is forged.
func is_permanent_prerequisite(item_id: String) -> bool:
	if item_id.begins_with("upgrades/"):
		return true
	if catalog == null or not catalog.capsules.has(item_id):
		return false
	var cap: Dictionary = catalog.capsules[item_id]
	var tags: Array = cap.get("tags", [])
	for t in tags:
		var ts := str(t)
		if ts == "skill_bracket" or ts == "craft_skill_mastery" or ts == "craft_homestead_station" or ts == "craft_achievement_relic" or ts.begins_with("skill_school_"):
			return true
	var affs: Array = cap.get("affordances", [])
	if affs.has("place_in_house"):
		return true
	return false


## Evaluates whether a vendor offer can currently be purchased by the player.
func can_buy_vendor_offer(vendor_id: String, offer: Dictionary) -> Dictionary:
	var req_depth := get_vendor_unlock_depth(vendor_id)
	if player_max_depth < req_depth:
		return {"can_buy": false, "reason": "Requires Z >= %d" % req_depth}
	var unlock_expr := str(offer.get("unlock_if", "")).strip_edges()
	if unlock_expr != "":
		var dummy_inst := {"capsule_id": str(offer.get("capsule_id", "")), "vars": {}}
		if rules.eval_expr(unlock_expr, dummy_inst, _build_env_neutral(player_tool)) <= 0.0:
			return {"can_buy": false, "reason": "Locked (%s)" % unlock_expr}
	var price: Dictionary = offer.get("price", {})
	for curr_id in price.keys():
		var req_qty := int(price[curr_id])
		if req_qty > 0 and not can_satisfy_requirement(str(curr_id), 0, req_qty):
			var c_name := str(catalog.capsules.get(str(curr_id), {}).get("meta", {}).get("name", str(curr_id)))
			if is_permanent_prerequisite(str(curr_id)):
				return {"can_buy": false, "reason": "Requires Skill/Station: %s" % c_name}
			return {"can_buy": false, "reason": "Need %d %s" % [req_qty, c_name]}
	return {"can_buy": true, "reason": "Available"}


var _last_consumed_sockets: Array = []

## Purchases or forges an offer from an NPC vendor/station (or grants it directly if free_grant is true), instantiating and routing the capsule.
func buy_vendor_offer(vendor_id: String, offer: Dictionary, free_grant: bool = false) -> Dictionary:
	_last_consumed_sockets.clear()
	if not free_grant:
		var chk := can_buy_vendor_offer(vendor_id, offer)
		if not bool(chk.get("can_buy", false)):
			return {"ok": false, "reason": str(chk.get("reason", "Cannot buy"))}
		var price: Dictionary = offer.get("price", {})
		for curr_id in price.keys():
			var req_qty := int(price[curr_id])
			if req_qty > 0 and not is_permanent_prerequisite(str(curr_id)):
				action_consume_item(str(curr_id), 0, req_qty)

	var cap_id := str(offer.get("capsule_id", ""))
	if not catalog.capsules.has(cap_id):
		return {"ok": false, "reason": "Unknown capsule " + cap_id}
	var inst := create_capsule_instance(cap_id)
	if not _last_consumed_sockets.is_empty():
		inst["sockets"] = _last_consumed_sockets.duplicate()
		_last_consumed_sockets.clear()
	player_owned_capsules.append(inst)

	var cap: Dictionary = catalog.capsules[cap_id]
	var affs: Array = cap.get("affordances", [])
	if affs.has("equip_tool") and (player_tool.is_empty() or str(player_tool.get("capsule_id", "")) == "" or bool(player_tool.get("destroyed", false))):
		equip_tool_instance(inst)
	elif affs.has("place_in_house") or (affs.has("carry") and not affs.has("equip_tool") and not affs.has("place_on_tile") and not affs.has("consume") and not affs.has("read_book")):
		equip_item(inst)

	return {"ok": true, "instance": inst}


## Sockets a socket_in_tool capsule instance into the target tool (default: active player_tool).
func socket_capsule_into_tool(socket_inst: Dictionary, target_tool: Dictionary = {}) -> bool:
	var tool_ref: Dictionary = player_tool if target_tool.is_empty() else target_tool
	if tool_ref.is_empty() or socket_inst.is_empty():
		return false
	var cid := str(socket_inst.get("capsule_id", ""))
	var affs: Array = catalog.capsules.get(cid, {}).get("affordances", [])
	if not affs.has("socket_in_tool"):
		return false
	if not tool_ref.has("sockets") or typeof(tool_ref["sockets"]) != TYPE_ARRAY:
		tool_ref["sockets"] = []
	var sockets_arr: Array = tool_ref["sockets"]
	if not sockets_arr.has(socket_inst):
		sockets_arr.append(socket_inst)
	rules.dispatch_event("on_equip", [socket_inst], _build_env_neutral(tool_ref), self)
	return true


## Transfers all auto-mined / routed items from paired_chest_loot into the player's main backpack inventory.
func claim_paired_chest() -> int:
	var total_claimed := 0
	for k in paired_chest_loot.keys():
		var qty := int(paired_chest_loot[k])
		if qty > 0:
			inventory[k] = int(inventory.get(k, 0)) + qty
			total_claimed += qty
	paired_chest_loot.clear()
	return total_claimed


## Sells all mined blocks in the player's backpack to the market and returns total gold earned.
func sell_all_inventory_ores() -> int:
	var total_gold := 0
	var keys := inventory.keys().duplicate()
	for k in keys:
		var ks := str(k)
		var parts := ks.split(":")
		if parts.size() == 2:
			var item_id := parts[0]
			var t_val := int(parts[1])
			var qty := int(inventory.get(ks, 0))
			if qty > 0:
				total_gold += sell_to_market(item_id, t_val, qty)
	return total_gold


## Hot-reloads newly downloaded or autonomously merged capsules without restarting or shifting active tile block IDs.
func hot_reload_catalog(extra_dirs: Array = []) -> Dictionary:
	var before_ids: Dictionary = {}
	for k in catalog.capsules.keys():
		before_ids[str(k)] = true

	# Snapshot active quarry tile string IDs before rebuilding block_int_to_id
	var n := cols * rows
	var saved_tile_blocks: Array[String] = []
	var saved_tile_cats: Array[String] = []
	saved_tile_blocks.resize(n)
	saved_tile_cats.resize(n)
	for i in n:
		var b_int := base_id[i]
		saved_tile_blocks[i] = catalog.block_int_to_id[b_int] if (b_int >= 0 and b_int < catalog.block_int_to_id.size()) else "blocks/stone"
		var c_int := placed_catalyst_id[i]
		saved_tile_cats[i] = catalog.block_int_to_id[c_int] if (c_int >= 0 and c_int < catalog.block_int_to_id.size()) else ""

	catalog.load_directory_into_catalog("res://content/capsules")
	var factory_mirror := "/home/joe/.local/share/lfs-tycoon-factory/repo/content/capsules"
	if DirAccess.dir_exists_absolute(factory_mirror):
		catalog.load_directory_into_catalog(factory_mirror)
	if DirAccess.dir_exists_absolute("user://live_capsules"):
		catalog.load_directory_into_catalog("user://live_capsules")
	for d in extra_dirs:
		var ds := str(d)
		if ds != "" and DirAccess.dir_exists_absolute(ds):
			catalog.load_directory_into_catalog(ds)

	catalog.rebuild_indexes()
	generator._init_noises()

	# Restore exact integer block IDs on all active tiles
	var stone_fallback := int(catalog.block_id_to_int.get("blocks/stone", 0))
	for i in n:
		base_id[i] = int(catalog.block_id_to_int.get(saved_tile_blocks[i], stone_fallback))
		placed_catalyst_id[i] = int(catalog.block_id_to_int.get(saved_tile_cats[i], -1)) if saved_tile_cats[i] != "" else -1

	var new_ids: Array[String] = []
	for k in catalog.capsules.keys():
		var ks := str(k)
		if not before_ids.has(ks):
			new_ids.append(ks)
	new_ids.sort()
	return {
		"added_count": new_ids.size(),
		"total_capsules": catalog.capsules.size(),
		"new_ids": new_ids
	}


## RuleEngine action hooks for consume_item, modify_depth, modify_fluid, transform_tile.
func action_consume_item(item_id: String, min_tier: int, qty: int) -> bool:
	if qty <= 0 or item_id == "":
		return false
	if not can_satisfy_requirement(item_id, min_tier, qty):
		return false
	var remaining := qty
	var prefix := item_id + ":"
	var matching_keys: Array[String] = []
	for k in inventory.keys():
		var ks := str(k)
		if ks.begins_with(prefix):
			var t_val := int(ks.split(":")[1])
			if t_val >= min_tier and int(inventory[ks]) > 0:
				matching_keys.append(ks)
	matching_keys.sort_custom(func(a: String, b: String) -> bool:
		return int(a.split(":")[1]) < int(b.split(":")[1])
	)
	for ks in matching_keys:
		if remaining <= 0:
			break
		var have := int(inventory.get(ks, 0))
		var take := mini(have, remaining)
		inventory[ks] = have - take
		remaining -= take
		if int(inventory[ks]) <= 0:
			inventory.erase(ks)

	# If remaining > 0, consume matching instances from player_owned_capsules (Terraria-style item fusion)
	if remaining > 0:
		for idx in range(player_owned_capsules.size() - 1, -1, -1):
			if remaining <= 0:
				break
			var inst: Dictionary = player_owned_capsules[idx]
			if not bool(inst.get("destroyed", false)) and str(inst.get("capsule_id", "")) == item_id:
				if inst.has("sockets") and typeof(inst["sockets"]) == TYPE_ARRAY:
					for s_inst in inst["sockets"]:
						if not _last_consumed_sockets.has(s_inst):
							_last_consumed_sockets.append(s_inst)
				inst["destroyed"] = true
				player_equipped_items.erase(inst)
				player_owned_capsules.remove_at(idx)
				remaining -= 1
	return true


func action_modify_depth(ox: int, oy: int, sel: String, delta: int, material_id: String, rng_host: Object) -> void:
	if delta == 0:
		return
	var coords := _resolve_target_coords(ox, oy, sel, rng_host)
	for pt in coords:
		var i := idx_of(pt.x, pt.y)
		if delta < 0:
			var steps := mini(-delta, depth[i])
			for _s in steps:
				_raise_floor(i, material_id)
			_evaluate_fluid_siphon_around(pt.x, pt.y)
		else:
			var new_z := depth[i] + delta
			depth[i] = new_z
			if new_z > max_depth_reached[i]:
				max_depth_reached[i] = new_z
			if new_z > player_max_depth:
				player_max_depth = new_z
			if depth[i] < max_depth_reached[i]:
				base_id[i] = int(catalog.block_id_to_int.get("blocks/dirt", 0))
				tier[i] = 0
				max_hp[i] = 5.0
				damage_accum[i] = 0.0
				fluid_type[i] = FLUID_NONE
				fluid_level[i] = 0
				tile_block_inst[i] = {}
			else:
				_populate_tile_from_generator(pt.x, pt.y, new_z, compute_local_imbalance(pt.x, pt.y))
				damage_accum[i] = 0.0
			_evaluate_fluid_siphon_around(pt.x, pt.y)


func action_modify_fluid(ox: int, oy: int, sel: String, fl_str: String, delta_lvl: int, rng_host: Object) -> void:
	var max_buckets := catalog.get_gmst_int("fMaxFluidBucketsPerTile", 9)
	var scoop_hp := catalog.get_gmst_float("fBucketScoopHp", 100.0)
	var coords := _resolve_target_coords(ox, oy, sel, rng_host)
	for pt in coords:
		var i := idx_of(pt.x, pt.y)
		if fl_str == "NONE" or (delta_lvl < 0 and fluid_level[i] + delta_lvl <= 0):
			if fluid_level[i] > 0:
				fluid_level[i] = 0
				fluid_type[i] = FLUID_NONE
				_restore_solid_hp_after_drain(i)
			continue
		var target_type := fluid_type[i]
		if fl_str == "WATER":
			target_type = FLUID_WATER
		elif fl_str == "LAVA":
			target_type = FLUID_LAVA
		if fluid_level[i] > 0 and fluid_type[i] != FLUID_NONE and target_type != FLUID_NONE and fluid_type[i] != target_type and delta_lvl > 0:
			fluid_level[i] = 0
			fluid_type[i] = FLUID_NONE
			if catalog.block_id_to_int.has("blocks/obsidian_hazard"):
				base_id[i] = int(catalog.block_id_to_int["blocks/obsidian_hazard"])
				var obs_st: Dictionary = catalog.capsules["blocks/obsidian_hazard"].get("stats", {})
				max_hp[i] = float(obs_st.get("base_hp", 500.0))
				damage_accum[i] = 0.0
				tile_block_inst[i] = {}
			var no_tool := {"capsule_id": "", "vars": {}}
			rules.dispatch_event("on_fluid_contact", _gather_active_instances(i, no_tool), _build_env(pt.x, pt.y, no_tool, false, false, 0.0), self)
			continue
		var new_lvl := clampi(fluid_level[i] + delta_lvl, 0, max_buckets)
		if new_lvl <= 0:
			fluid_level[i] = 0
			fluid_type[i] = FLUID_NONE
			_restore_solid_hp_after_drain(i)
		else:
			if target_type == FLUID_NONE:
				target_type = FLUID_WATER
			fluid_type[i] = target_type
			fluid_level[i] = new_lvl
			max_hp[i] = float(new_lvl) * scoop_hp
			damage_accum[i] = 0.0
		_evaluate_fluid_siphon_around(pt.x, pt.y)


func action_transform_tile(ox: int, oy: int, sel: String, block_id: String, set_tier: int, rng_host: Object) -> void:
	if not catalog.block_id_to_int.has(block_id):
		return
	var blk_int := int(catalog.block_id_to_int[block_id])
	var st: Dictionary = catalog.capsules.get(block_id, {}).get("stats", {})
	var base_hp_val := float(st.get("base_hp", 10.0))
	var coords := _resolve_target_coords(ox, oy, sel, rng_host)
	for pt in coords:
		var i := idx_of(pt.x, pt.y)
		base_id[i] = blk_int
		if set_tier >= 0:
			tier[i] = set_tier
		tile_block_inst[i] = {}
		if fluid_level[i] <= 0:
			max_hp[i] = base_hp_val * pow(1.8, float(tier[i]))
			damage_accum[i] = 0.0


func _block_inst_at(tile_idx: int) -> Dictionary:
	var blk_id := catalog.block_int_to_id[base_id[tile_idx]]
	var cap: Dictionary = catalog.capsules.get(blk_id, {})
	if cap.is_empty():
		return {}
	if cap.get("modifiers", []).is_empty() and cap.get("reactions", []).is_empty():
		return {}
	var cur: Dictionary = tile_block_inst[tile_idx]
	if cur.is_empty() or str(cur.get("capsule_id", "")) != blk_id or bool(cur.get("destroyed", false)):
		cur = create_capsule_instance(blk_id)
		tile_block_inst[tile_idx] = cur
	return cur


func _player_instances() -> Array:
	var out: Array = []
	if not player_tool.is_empty() and str(player_tool.get("capsule_id", "")) != "" and not bool(player_tool.get("destroyed", false)):
		player_tool["is_covering_current_tile"] = false
		out.append(player_tool)
		for s in player_tool.get("sockets", []):
			if s is Dictionary and not bool(s.get("destroyed", false)):
				s["is_covering_current_tile"] = false
				out.append(s)
	for eq in player_equipped_items:
		if not bool(eq.get("destroyed", false)):
			eq["is_covering_current_tile"] = false
			out.append(eq)
			for s in eq.get("sockets", []):
				if s is Dictionary and not bool(s.get("destroyed", false)):
					s["is_covering_current_tile"] = false
					out.append(s)
	return out


func _prune_player_items() -> void:
	for k in range(player_equipped_items.size() - 1, -1, -1):
		if bool(player_equipped_items[k].get("destroyed", false)):
			player_equipped_items.remove_at(k)
	for k in range(player_owned_capsules.size() - 1, -1, -1):
		if bool(player_owned_capsules[k].get("destroyed", false)):
			player_owned_capsules.remove_at(k)


func _gather_active_instances(tile_idx: int, tool_inst: Dictionary) -> Array:
	var out: Array = []
	if not tool_inst.is_empty() and str(tool_inst.get("capsule_id", "")) != "" and not bool(tool_inst.get("destroyed", false)):
		tool_inst["is_covering_current_tile"] = false
		out.append(tool_inst)
		for s in tool_inst.get("sockets", []):
			if s is Dictionary and not bool(s.get("destroyed", false)):
				s["is_covering_current_tile"] = false
				out.append(s)
	for eq in player_equipped_items:
		if not bool(eq.get("destroyed", false)):
			eq["is_covering_current_tile"] = false
			out.append(eq)
			for s in eq.get("sockets", []):
				if s is Dictionary and not bool(s.get("destroyed", false)):
					s["is_covering_current_tile"] = false
					out.append(s)
	for att in tile_attachments[tile_idx]:
		if not bool(att.get("destroyed", false)):
			att["is_covering_current_tile"] = true
			out.append(att)
			for s in att.get("sockets", []):
				if s is Dictionary and not bool(s.get("destroyed", false)):
					s["is_covering_current_tile"] = true
					out.append(s)
	var blk_inst := _block_inst_at(tile_idx)
	if not blk_inst.is_empty() and not bool(blk_inst.get("destroyed", false)):
		blk_inst["is_covering_current_tile"] = true
		out.append(blk_inst)
	var b_id := tile_biome_id[tile_idx]
	if b_id != "" and biome_insts.has(b_id):
		var b_inst: Dictionary = biome_insts[b_id]
		if not bool(b_inst.get("destroyed", false)):
			b_inst["is_covering_current_tile"] = true
			out.append(b_inst)
	return out


func _build_env_neutral(tool_inst: Dictionary) -> Dictionary:
	return _build_env(0, 0, tool_inst, false, false, 0.0)


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
			var pick_idx := int(rng_host.call("pick_index", out.size()))
			return [out[pick_idx]]
		elif sel == "shallowest_neighbor_4" and not out.is_empty():
			out.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
				return depth[idx_of(a.x, a.y)] < depth[idx_of(b.x, b.y)]
			)
			return [out[0]]
	elif sel == "neighbors_8" or sel == "random_neighbor_8" or sel == "shallowest_neighbor_8":
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				if (dx != 0 or dy != 0) and in_bounds(ox + dx, oy + dy):
					out.append(Vector2i(ox + dx, oy + dy))
		if sel == "random_neighbor_8" and not out.is_empty():
			var pick_idx := int(rng_host.call("pick_index", out.size()))
			return [out[pick_idx]]
		elif sel == "shallowest_neighbor_8" and not out.is_empty():
			out.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
				return depth[idx_of(a.x, a.y)] < depth[idx_of(b.x, b.y)]
			)
			return [out[0]]
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

