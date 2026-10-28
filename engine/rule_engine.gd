class_name RuleEngine
extends RefCounted
## Evaluates Modifiers (Law L6: base/add/mul/clamp) and Reactions (Law L1/L7/L8: WHEN/IF/DO)
## with pre-compiled Expression slots, deterministic seeded RNG, cascade depth <= 4, and per-frame budget deferral.

class SafeExprHost extends RefCounted:
	var rng_state: int = 0x1E3779B97F4A7C15

	func _next_u() -> float:
		# Deterministic SplitMix64 step (63-bit signed-safe hex constants)
		rng_state = (rng_state + 0x1E3779B97F4A7C15) & 0x7FFFFFFFFFFFFFFF
		var z := rng_state
		z = ((z ^ (z >> 30)) * 0x3F58476D1CE4E5B9) & 0x7FFFFFFFFFFFFFFF
		z = ((z ^ (z >> 27)) * 0x14D049BB133111EB) & 0x7FFFFFFFFFFFFFFF
		z = z ^ (z >> 31)
		return float(z & 0xFFFFFF) / float(0x1000000)

	func roll(prob: float) -> float:
		return 1.0 if _next_u() < prob else 0.0

	## Uniform deterministic index in [0, n). Used by random_* target selectors.
	func pick_index(n: int) -> int:
		if n <= 0:
			return 0
		return mini(n - 1, int(_next_u() * float(n)))

	## Converts a boolean comparison result into 1.0 / 0.0 when used inside arithmetic.
	func _b(cond: Variant) -> float:
		return 1.0 if bool(cond) else 0.0


var catalog: CatalogDB
var expr_host: SafeExprHost = SafeExprHost.new()
var shared_registers: Dictionary = {}      # key -> float
var ui_flags: Dictionary = {
	"hud_chalk_lines": false,
	"hud_chess_grid": false,
	"hud_target_loupe": false,
	"hud_depth_calipers": false,
	"hud_durability_bars": false,
	"hud_battery_timers": false
}
var alerts_emitted: Array[Dictionary] = []
var deferred_queue: Array[Dictionary] = []
var runtime_quarantined: Dictionary = {}   # capsule_id -> error reason

var _compiled_cache: Dictionary = {}       # raw_expr_str -> Dictionary {expr, vars}
var _cascade_depth: int = 0
var _max_cascade_depth: int = 4
var _frame_budget_us: int = 1500
var _dot_regex: RegEx
var _arith_cmp_left_regex: RegEx
var _arith_cmp_right_regex: RegEx


func _init(p_catalog: CatalogDB, seed_val: int = 1337) -> void:
	catalog = p_catalog
	expr_host.rng_state = seed_val ^ 0x5DEECE66D
	_max_cascade_depth = catalog.get_gmst_int("fMaxCascadeDepth", 4)
	_frame_budget_us = catalog.get_gmst_int("fFrameReactionBudgetUs", 1500)
	_dot_regex = RegEx.new()
	_dot_regex.compile("\\b(self\\.stats|self|tile|player|tool|ctx|shared)\\.([a-zA-Z0-9_]+)")
	_arith_cmp_left_regex = RegEx.new()
	_arith_cmp_left_regex.compile("([\\+\\-\\*/]\\s*)\\(([^()]+?(?:>=|<=|==|!=|>|<)[^()]+?)\\)")
	_arith_cmp_right_regex = RegEx.new()
	_arith_cmp_right_regex.compile("\\(([^()]+?(?:>=|<=|==|!=|>|<)[^()]+?)\\)(\\s*[\\+\\-\\*/])")
	reset_shared_registers()


func reset_shared_registers() -> void:
	shared_registers.clear()
	for k in catalog.vocab_shared_vars.keys():
		var spec: Dictionary = catalog.vocab_shared_vars[k]
		shared_registers[k] = float(spec.get("default", 0.0))


## Pre-compiles an expression string into a fast slot-bound Godot Expression.
func compile_expr(raw_expr: String) -> Dictionary:
	if _compiled_cache.has(raw_expr):
		return _compiled_cache[raw_expr]

	var input_names := PackedStringArray()
	var slot_specs: Array[Dictionary] = []
	var seen: Dictionary = {}
	var rewritten := raw_expr

	var matches := _dot_regex.search_all(raw_expr)
	# Replace longest/all matches with flat variable names
	for m in matches:
		var full := m.get_string(0)
		var scope := m.get_string(1)
		var key := m.get_string(2)
		var slot_name := "_" + scope.replace(".", "_") + "__" + key
		if not seen.has(slot_name):
			seen[slot_name] = true
			input_names.append(slot_name)
			slot_specs.append({"scope": scope, "key": key})
		rewritten = rewritten.replace(full, slot_name)

	rewritten = _arith_cmp_left_regex.sub(rewritten, "$1_b($2)", true)
	rewritten = _arith_cmp_right_regex.sub(rewritten, "_b($1)$2", true)

	var expr := Expression.new()
	var err := expr.parse(rewritten, input_names)
	var entry := {
		"ok": (err == OK),
		"expr": expr,
		"slots": slot_specs,
		"raw": raw_expr,
		"error": expr.get_error_text() if err != OK else ""
	}
	_compiled_cache[raw_expr] = entry
	return entry


func eval_expr(raw_expr: String, instance: Dictionary, env: Dictionary) -> float:
	var c := compile_expr(raw_expr)
	if not bool(c["ok"]):
		_quarantine_instance(instance, "Expression compile error: " + str(c["error"]))
		return 0.0

	var slots: Array = c["slots"]
	var args := Array()
	args.resize(slots.size())
	var cap_id := str(instance.get("capsule_id", ""))
	var cap_def: Dictionary = catalog.capsules.get(cap_id, {})
	var cap_stats: Dictionary = cap_def.get("stats", {})
	var inst_vars: Dictionary = instance.get("vars", {})

	for i in slots.size():
		var s: Dictionary = slots[i]
		var sc: String = s["scope"]
		var k: String = s["key"]
		if sc == "self.stats":
			args[i] = float(cap_stats.get(k, 0.0))
		elif sc == "self":
			if inst_vars.has(k):
				args[i] = float(inst_vars[k])
			else:
				args[i] = float(cap_stats.get(k, 0.0))
		elif sc == "shared":
			args[i] = float(shared_registers.get(k, 0.0))
		elif env.has(sc):
			var sub: Dictionary = env[sc]
			args[i] = float(sub.get(k, 0.0))
		else:
			args[i] = 0.0

	var expr: Expression = c["expr"]
	var res: Variant = expr.execute(args, expr_host, false)
	if expr.has_execute_failed():
		_quarantine_instance(instance, "Runtime expression failure in: " + raw_expr)
		return 0.0
	if typeof(res) == TYPE_BOOL:
		return 1.0 if bool(res) else 0.0
	var f_val := float(res)
	if is_nan(f_val) or is_inf(f_val):
		_quarantine_instance(instance, "NaN/Inf produced by expression: " + raw_expr)
		return 0.0
	return f_val


## Law L6: Evaluates a modifiable stat across active capsule instances in deterministic order
## (base -> add -> mul -> floor/clamp). `clamp` is an upper cap, `floor` is a lower bound.
func resolve_stat(stat_name: String, base_value: float, active_instances: Array, env: Dictionary) -> float:
	var val_base := base_value
	var val_add := 0.0
	var val_mul := 1.0
	var clamp_min := -INF
	var clamp_max := INF

	for inst in active_instances:
		if bool(inst.get("destroyed", false)):
			continue
		var cap_id := str(inst.get("capsule_id", ""))
		if runtime_quarantined.has(cap_id) or not catalog.capsules.has(cap_id):
			continue
		var cap_def: Dictionary = catalog.capsules[cap_id]
		var mods: Array = cap_def.get("modifiers", [])
		if mods.is_empty():
			continue

		# Set tile.covered_by_self if this instance is placed on the queried tile
		if env.has("tile"):
			env["tile"]["covered_by_self"] = 1.0 if bool(inst.get("is_covering_current_tile", false)) else 0.0

		for mod in mods:
			if str(mod.get("stat", "")) != stat_name:
				continue
			if mod.has("if"):
				var cond := eval_expr(str(mod["if"]), inst, env)
				if cond <= 0.0:
					continue
			var m_val := eval_expr(str(mod.get("value", "0.0")), inst, env)
			var phase := str(mod.get("phase", "add"))
			if phase == "base":
				val_base = m_val
			elif phase == "add":
				val_add += m_val
			elif phase == "mul":
				val_mul *= m_val
			elif phase == "floor":
				clamp_min = maxf(clamp_min, m_val)
			elif phase == "clamp":
				clamp_max = minf(clamp_max, m_val)

	var out := (val_base + val_add) * val_mul
	if clamp_min > -INF:
		out = maxf(out, clamp_min)
	if clamp_max < INF:
		out = minf(out, clamp_max)
	return out


## Law L1/L7/L8: Dispatches an event to all active capsule instances with cascade depth and frame time budget guards.
func dispatch_event(
	event_name: String,
	active_instances: Array,
	env: Dictionary,
	grid_Host: Object = null,
	enforce_frame_budget: bool = true
) -> Dictionary:
	var summary := {
		"actions_executed": 0,
		"deferred_count": 0,
		"pause_battery": false,
		"pause_durability": false,
		"destroyed_instance_ids": []
	}
	if _cascade_depth >= _max_cascade_depth:
		return summary

	_cascade_depth += 1
	var t_start := Time.get_ticks_usec()

	for inst in active_instances:
		if bool(inst.get("destroyed", false)):
			continue
		var cap_id := str(inst.get("capsule_id", ""))
		if runtime_quarantined.has(cap_id) or not catalog.capsules.has(cap_id):
			continue
		var cap_def: Dictionary = catalog.capsules[cap_id]
		var reactions: Array = cap_def.get("reactions", [])
		if reactions.is_empty():
			continue

		if enforce_frame_budget and (Time.get_ticks_usec() - t_start) > _frame_budget_us:
			deferred_queue.append({"event": event_name, "instance": inst, "env": env.duplicate(true)})
			summary["deferred_count"] += 1
			continue

		if env.has("tile"):
			env["tile"]["covered_by_self"] = 1.0 if bool(inst.get("is_covering_current_tile", false)) else 0.0

		for rx in reactions:
			if str(rx.get("on", "")) != event_name:
				continue
			if rx.has("if"):
				if eval_expr(str(rx["if"]), inst, env) <= 0.0:
					continue
			for act_obj in rx.get("do", []):
				if act_obj.has("if"):
					if eval_expr(str(act_obj["if"]), inst, env) <= 0.0:
						continue
				_execute_action(act_obj, inst, env, grid_Host, summary)
				summary["actions_executed"] += 1

	_cascade_depth -= 1
	return summary


func flush_deferred_queue(grid_host: Object = null, max_us: int = 1000) -> int:
	var t0 := Time.get_ticks_usec()
	var processed := 0
	while not deferred_queue.is_empty() and (Time.get_ticks_usec() - t0) < max_us:
		var item: Dictionary = deferred_queue.pop_front()
		dispatch_event(str(item["event"]), [item["instance"]], item["env"], grid_host, false)
		processed += 1
	return processed


func _execute_action(act_obj: Dictionary, inst: Dictionary, env: Dictionary, grid_host: Object, summary: Dictionary) -> void:
	var act := str(act_obj.get("act", ""))
	var inst_vars: Dictionary = inst.get("vars", {})

	if act == "var_set" or act == "var_add":
		var target_var := str(act_obj.get("var", ""))
		var expr_str := str(act_obj.get("value" if act == "var_set" else "by", "0.0"))
		var delta := eval_expr(expr_str, inst, env)
		if target_var.begins_with("self."):
			var k := target_var.substr(5)
			var cur := float(inst_vars.get(k, 0.0))
			inst_vars[k] = delta if act == "var_set" else (cur + delta)
		elif target_var.begins_with("shared."):
			var k := target_var.substr(7)
			var spec: Dictionary = catalog.vocab_shared_vars.get(k, {})
			var cur := float(shared_registers.get(k, 0.0))
			var next_v := delta if act == "var_set" else (cur + delta)
			shared_registers[k] = clampf(next_v, float(spec.get("min", -1e9)), float(spec.get("max", 1e9)))
	elif act == "deal_damage":
		var dmg := eval_expr(str(act_obj.get("amount", "0.0")), inst, env)
		if dmg > 0.0 and grid_host != null and grid_host.has_method("apply_secondary_damage"):
			var target_sel := str(act_obj.get("target", "self_tile"))
			grid_host.call("apply_secondary_damage", _origin_x(env), _origin_y(env), target_sel, dmg, expr_host)
	elif act == "emit_alert":
		alerts_emitted.append({
			"channel": str(act_obj.get("channel", "house_bell")),
			"tag": str(act_obj.get("tag", "alert")),
			"capsule_id": str(inst.get("capsule_id", ""))
		})
	elif act == "set_ui_flag":
		var flag_name := str(act_obj.get("flag", ""))
		ui_flags[flag_name] = bool(act_obj.get("enabled", true))
	elif act == "stall_tool":
		if bool(act_obj.get("pause_battery", false)):
			summary["pause_battery"] = true
		if bool(act_obj.get("pause_durability", false)):
			summary["pause_durability"] = true
	elif act == "destroy_self":
		inst["destroyed"] = true
		summary["destroyed_instance_ids"].append(inst.get("uid", -1))
	elif act == "transmute_self":
		var into_id := str(act_obj.get("into", ""))
		if catalog.capsules.has(into_id):
			inst["capsule_id"] = into_id
	elif act == "spawn_item":
		if grid_host != null and grid_host.has_method("grant_inventory_item"):
			var item_id := str(act_obj.get("item", ""))
			var qty := int(round(eval_expr(str(act_obj.get("qty", "1")), inst, env)))
			var tier := int(round(eval_expr(str(act_obj.get("tier", "0")), inst, env))) if act_obj.has("tier") else 0
			var route := str(act_obj.get("route", "backpack"))
			grid_host.call("grant_inventory_item", item_id, tier, qty, route)
	elif act == "consume_item":
		if grid_host != null and grid_host.has_method("action_consume_item"):
			var c_qty := int(round(eval_expr(str(act_obj.get("qty", "1")), inst, env)))
			var c_tier := int(round(eval_expr(str(act_obj.get("tier", "0")), inst, env))) if act_obj.has("tier") else 0
			grid_host.call("action_consume_item", str(act_obj.get("item", "")), c_tier, c_qty)
	elif act == "modify_depth":
		if grid_host != null and grid_host.has_method("action_modify_depth"):
			var d_delta := int(round(eval_expr(str(act_obj.get("delta", "0")), inst, env)))
			var mat_id := str(act_obj.get("material", "blocks/dirt"))
			grid_host.call("action_modify_depth", _origin_x(env), _origin_y(env), str(act_obj.get("target", "self_tile")), d_delta, mat_id, expr_host)
	elif act == "modify_fluid":
		if grid_host != null and grid_host.has_method("action_modify_fluid"):
			var f_delta := int(round(eval_expr(str(act_obj.get("delta_level", "0")), inst, env)))
			grid_host.call("action_modify_fluid", _origin_x(env), _origin_y(env), str(act_obj.get("target", "self_tile")),
				str(act_obj.get("fluid_type", "NONE")), f_delta, expr_host)
	elif act == "transform_tile":
		if grid_host != null and grid_host.has_method("action_transform_tile"):
			var t_tier := int(round(eval_expr(str(act_obj.get("tier", "-1")), inst, env))) if act_obj.has("tier") else -1
			grid_host.call("action_transform_tile", _origin_x(env), _origin_y(env), str(act_obj.get("target", "self_tile")),
				str(act_obj.get("block", "")), t_tier, expr_host)


func _origin_x(env: Dictionary) -> int:
	return int(env.get("tile", {}).get("x", -1))


func _origin_y(env: Dictionary) -> int:
	return int(env.get("tile", {}).get("y", -1))


func _quarantine_instance(inst: Dictionary, reason: String) -> void:
	var cap_id := str(inst.get("capsule_id", "unknown"))
	runtime_quarantined[cap_id] = reason
	catalog.quarantined[cap_id] = reason
