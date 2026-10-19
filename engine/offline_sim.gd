class_name OfflineSim
extends RefCounted
## Decision D2 & Spike S1: 3-Mode Offline Simulator (coarse | exact | none).
## Fast-forwards 24h x 20 stationed auto-tools in milliseconds by walking deterministic 3D columns.

static func simulate_offline(grid: GridManager, away_seconds: float) -> Dictionary:
	var t0_us := Time.get_ticks_usec()
	var total_blocks_mined := 0
	var tools_stalled := 0
	var tools_depleted := 0
	var exact_budget_us := grid.catalog.get_gmst_int("fOfflineExactBudgetMs", 250) * 1000
	var min_break_sec := grid.catalog.get_gmst_float("fMinBreakTimeSec", 1.0)
	var gate_sec := grid.catalog.get_gmst_float("fRefreshGateSec", 0.05)

	for y in grid.rows:
		for x in grid.cols:
			var i := grid.idx_of(x, y)
			var atts: Array = grid.tile_attachments[i]
			if atts.is_empty():
				continue

			for inst in atts:
				if bool(inst.get("destroyed", false)):
					continue
				var cid := str(inst.get("capsule_id", ""))
				if not grid.catalog.capsules.has(cid):
					continue
				var cap: Dictionary = grid.catalog.capsules[cid]
				var mode := str(cap.get("offline", "none"))
				if mode == "none":
					continue

				if mode == "coarse" and cap.get("tags", []).has("automine"):
					var res := _simulate_coarse_column(grid, x, y, inst, away_seconds, min_break_sec, gate_sec)
					total_blocks_mined += int(res["blocks_mined"])
					if bool(res["stalled"]):
						tools_stalled += 1
					if bool(res["depleted"]):
						tools_depleted += 1
				elif mode == "exact" and cap.get("tags", []).has("automine"):
					# Discrete-event exact step bounded by wall-clock budget
					var rem := away_seconds
					while rem > 0.0 and not bool(inst.get("destroyed", false)):
						if (Time.get_ticks_usec() - t0_us) > exact_budget_us:
							break
						var dt := minf(rem, 1.0)
						var tick_res := grid.apply_mining_tick(x, y, inst, dt, false)
						if bool(tick_res.get("broke", false)):
							total_blocks_mined += 1
						rem -= dt
						if bool(tick_res.get("stalled", false)):
							tools_stalled += 1
							break
			grid._cleanup_destroyed_attachments(i)

	var elapsed_ms := float(Time.get_ticks_usec() - t0_us) / 1000.0
	return {
		"elapsed_ms": elapsed_ms,
		"blocks_mined": total_blocks_mined,
		"tools_stalled": tools_stalled,
		"tools_depleted": tools_depleted
	}


static func _simulate_coarse_column(
	grid: GridManager,
	x: int,
	y: int,
	tool_inst: Dictionary,
	away_seconds: float,
	min_break_sec: float,
	gate_sec: float
) -> Dictionary:
	var i := grid.idx_of(x, y)
	var cap: Dictionary = grid.catalog.capsules[str(tool_inst["capsule_id"])]
	var st: Dictionary = cap.get("stats", {})
	var tool_type_str := str(st.get("tool_type", "PICKAXE"))
	var tool_tier_val := int(st.get("tool_tier", 0))
	var base_dps := float(st.get("base_dps", 10.0))
	var iv: Dictionary = tool_inst.get("vars", {})

	var has_charge := iv.has("charge_left")
	var charge_rem := float(iv.get("charge_left", away_seconds))
	var has_dur := iv.has("durability_left")
	var dur_rem := float(iv.get("durability_left", 999999.0))

	var time_rem := minf(away_seconds, charge_rem) if has_charge else away_seconds
	var mined := 0
	var stalled := false
	var depleted := false

	while time_rem > 0.0 and dur_rem > 0.0:
		var is_fluid := (grid.fluid_level[i] > 0 and grid.fluid_type[i] != GridManager.FLUID_NONE)
		var blk_id := grid.catalog.block_int_to_id[grid.base_id[i]]
		var blk_st: Dictionary = grid.catalog.capsules.get(blk_id, {}).get("stats", {})
		var ideal_tool := "BUCKET" if is_fluid else str(blk_st.get("ideal_tool", "PICKAXE"))
		var strict_lock := true if is_fluid else (int(blk_st.get("strict_tool_lock", 0)) == 1)

		if strict_lock and tool_type_str != ideal_tool:
			# Hit water or hazard while offline! Fire stall event once and halt column advancement.
			stalled = true
			var active_insts := grid._gather_active_instances(i, tool_inst)
			var env := grid._build_env(x, y, tool_inst, false, false, 0.0)
			var stall_res := grid.rules.dispatch_event("on_zero_damage_stall", active_insts, env, grid, false)
			if not bool(stall_res["pause_battery"]) and has_charge:
				charge_rem = maxf(0.0, charge_rem - time_rem)
				if charge_rem <= 0.0:
					depleted = true
					tool_inst["destroyed"] = (int(st.get("is_rechargeable", 1)) == 0)
			if not bool(stall_res["pause_durability"]) and has_dur:
				dur_rem = maxf(0.0, dur_rem - time_rem)
			break

		var pen := grid.compute_wrong_tool_penalty(tool_type_str, tool_tier_val, ideal_tool, grid.tier[i])
		var eff_dps := base_dps / (1.0 + pen)
		var rem_hp := maxf(0.1, grid.max_hp[i] - grid.damage_accum[i])
		var break_sec := maxf(min_break_sec, rem_hp / maxf(0.1, eff_dps)) + gate_sec

		if time_rem >= break_sec:
			time_rem -= break_sec
			if has_charge:
				charge_rem = maxf(0.0, charge_rem - break_sec)
			if has_dur:
				dur_rem = maxf(0.0, dur_rem - 1.0)
			grid.damage_accum[i] = 0.0
			grid._complete_block_break(x, y, tool_inst)
			mined += 1
			if (has_charge and charge_rem <= 0.0) or (has_dur and dur_rem <= 0.0):
				depleted = true
				if int(st.get("is_rechargeable", 1)) == 0:
					tool_inst["destroyed"] = true
				break
		else:
			# Partial damage accumulated on the final block (100% persistent!)
			var partial_dmg := (rem_hp / break_sec) * time_rem
			grid.damage_accum[i] = minf(grid.max_hp[i] - 0.01, grid.damage_accum[i] + partial_dmg)
			if has_charge:
				charge_rem = maxf(0.0, charge_rem - time_rem)
			time_rem = 0.0
			break

	if has_charge:
		iv["charge_left"] = charge_rem
	if has_dur:
		iv["durability_left"] = dur_rem

	return {"blocks_mined": mined, "stalled": stalled, "depleted": depleted}
