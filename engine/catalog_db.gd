class_name CatalogDB
extends RefCounted
## Antifragile Capsule Loader, Reverse Indexer & Runtime Quarantine Engine (Laws L1-L12).

var gmst: Dictionary = {}
var vocab_events: Dictionary = {}
var vocab_actions: Dictionary = {}
var vocab_affordances: Dictionary = {}
var vocab_shared_vars: Dictionary = {}

var capsules: Dictionary = {}              # cap_id -> Dictionary (validated capsule record)
var quarantined: Dictionary = {}           # cap_id -> String (reason for quarantine)
var vendor_catalog: Dictionary = {}        # vendor_id -> Array[Dictionary] (reverse index)
var block_ids_sorted: PackedStringArray = PackedStringArray()
var biome_ids: PackedStringArray = PackedStringArray()
var block_int_to_id: PackedStringArray = PackedStringArray()
var block_id_to_int: Dictionary = {}

const FORBIDDEN_EXPR_TOKENS: Array[String] = [
	"OS.", "Engine.", "FileAccess.", "DirAccess.", "ClassDB.",
	"ProjectSettings.", "DisplayServer.", "RenderingServer.",
	"randf(", "randi(", "randfn(", "randf_range(", "randi_range(",
	"__", "/ 0", "/0"
]


func load_all(capsules_root: String = "res://content/capsules") -> void:
	gmst = _load_json_dict("res://vocab/gmst.json").get("globals", {})
	vocab_events = _load_json_dict("res://vocab/events.json")
	vocab_actions = _load_json_dict("res://vocab/actions.json").get("actions", {})
	vocab_affordances = _load_json_dict("res://vocab/affordances.json")
	vocab_shared_vars = _load_json_dict("res://vocab/shared_vars.json").get("shared_vars", {})

	capsules.clear()
	quarantined.clear()
	vendor_catalog.clear()
	block_ids_sorted.clear()
	biome_ids.clear()
	block_int_to_id.clear()
	block_id_to_int.clear()

	load_directory_into_catalog(capsules_root)
	if capsules_root == "res://content/capsules" and DirAccess.dir_exists_absolute("user://live_capsules"):
		load_directory_into_catalog("user://live_capsules")
	rebuild_indexes()


func load_directory_into_catalog(capsules_root: String) -> void:
	var raw_candidates: Dictionary = _discover_capsule_files(capsules_root)
	# First pass: structural, syntax, and local expression safety
	var stage1: Dictionary = {}
	for cap_id in raw_candidates.keys():
		var path: String = raw_candidates[cap_id]
		var res: Dictionary = _parse_and_validate_local(cap_id, path)
		if res.has("error"):
			quarantined[cap_id] = str(res["error"])
		else:
			stage1[cap_id] = res["data"]

	# Known valid IDs include already loaded capsules plus stage1 candidates
	var known_ids: Dictionary = {}
	for k in capsules.keys():
		known_ids[k] = true
	for k in stage1.keys():
		known_ids[k] = true

	# Second pass: backward references and Law L11 economy containment
	for cap_id in stage1.keys():
		var data: Dictionary = stage1[cap_id]
		var ref_err: String = _validate_references_and_economy(cap_id, data, known_ids, stage1)
		if ref_err != "":
			quarantined[cap_id] = ref_err
		else:
			capsules[cap_id] = data


func rebuild_indexes() -> void:
	vendor_catalog.clear()
	biome_ids.clear()
	block_int_to_id.clear()
	block_id_to_int.clear()

	const CORE_BLOCKS := {
		"blocks/obsidian_hazard": true,
		"blocks/lava_pocket": true,
		"blocks/water_aquifer": true,
		"blocks/quartz_vein": true,
		"blocks/copper": true,
		"blocks/dirt": true,
		"blocks/stone": true
	}
	var block_records: Array[Dictionary] = []
	for cap_id in capsules.keys():
		var data: Dictionary = capsules[cap_id]
		var affs: Array = data.get("affordances", [])
		if affs.has("mineable_block"):
			var raw_rank := int(data.get("stats", {}).get("priority_rank", 100))
			var eff_rank := raw_rank if CORE_BLOCKS.has(cap_id) else maxi(100, raw_rank)
			block_records.append({"id": cap_id, "rank": eff_rank})
		if affs.has("biome_profile"):
			biome_ids.append(cap_id)
		for offer in data.get("offered_by", []):
			var v_id: String = str(offer.get("vendor", ""))
			if not vendor_catalog.has(v_id):
				vendor_catalog[v_id] = []
			vendor_catalog[v_id].append({
				"capsule_id": cap_id,
				"price": offer.get("price", {}),
				"unlock_if": str(offer.get("unlock_if", ""))
			})

	biome_ids.sort()
	block_records.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["rank"] != b["rank"]:
			return int(a["rank"]) < int(b["rank"])
		return str(a["id"]) < str(b["id"])
	)
	block_ids_sorted.clear()
	for idx in block_records.size():
		var bid: String = block_records[idx]["id"]
		block_ids_sorted.append(bid)
		block_int_to_id.append(bid)
		block_id_to_int[bid] = idx


func get_gmst_float(key: String, fallback: float) -> float:
	return float(gmst.get(key, fallback))


func get_gmst_int(key: String, fallback: int) -> int:
	return int(gmst.get(key, fallback))


func _discover_capsule_files(root_path: String) -> Dictionary:
	var out: Dictionary = {}
	var d_root := DirAccess.open(root_path)
	if d_root == null:
		return out
	d_root.list_dir_begin()
	var ns := d_root.get_next()
	while ns != "":
		if d_root.current_is_dir() and not ns.begins_with("."):
			var ns_path := root_path.path_join(ns)
			var d_ns := DirAccess.open(ns_path)
			if d_ns != null:
				d_ns.list_dir_begin()
				var slug := d_ns.get_next()
				while slug != "":
					if d_ns.current_is_dir() and not slug.begins_with("."):
						var cap_file := ns_path.path_join(slug).path_join("capsule.json")
						if FileAccess.file_exists(cap_file):
							out[ns + "/" + slug] = cap_file
					slug = d_ns.get_next()
		ns = d_root.get_next()
	return out


func _parse_and_validate_local(cap_id: String, file_path: String) -> Dictionary:
	var f := FileAccess.open(file_path, FileAccess.READ)
	if f == null:
		return {"error": "Cannot open file " + file_path}
	var raw := f.get_as_text()
	if raw.strip_edges() == "":
		return {"error": "Empty JSON file"}

	# Law L9: Reject trailing commas and duplicate keys that Godot JSON.parse silently ignores
	var tc_err := _check_raw_json_hazards(raw)
	if tc_err != "":
		return {"error": tc_err}

	var j := JSON.new()
	if j.parse(raw) != OK:
		return {"error": "JSON syntax error at line %d: %s" % [j.get_error_line(), j.get_error_message()]}
	if typeof(j.data) != TYPE_DICTIONARY:
		return {"error": "Root JSON must be an object"}

	var data: Dictionary = j.data
	if data.has("id") and str(data["id"]) != cap_id:
		return {"error": "Law L2: explicit id '%s' mismatches folder '%s'" % [str(data["id"]), cap_id]}
	if int(data.get("schema", 0)) != 1:
		return {"error": "Unsupported schema version"}
	var meta: Variant = data.get("meta")
	if typeof(meta) != TYPE_DICTIONARY or str(meta.get("name", "")).strip_edges() == "":
		return {"error": "Missing meta.name"}

	var valid_affs: Array = vocab_affordances.get("affordances", [])
	var affs: Variant = data.get("affordances")
	if typeof(affs) != TYPE_ARRAY or affs.is_empty():
		return {"error": "affordances must be a non-empty array"}
	for a in affs:
		if not valid_affs.has(str(a)):
			return {"error": "Unknown affordance '%s'" % str(a)}

	var stats: Dictionary = data.get("stats", {})
	if stats.has("base_hp") and float(stats["base_hp"]) <= 0.0:
		return {"error": "stats.base_hp must be > 0"}
	if stats.has("l_step") and float(stats["l_step"]) <= 0.0:
		return {"error": "stats.l_step must be > 0"}
	if stats.has("clump_xy") and float(stats["clump_xy"]) <= 0.0:
		return {"error": "stats.clump_xy must be > 0"}
	if stats.has("pipe_z") and float(stats["pipe_z"]) <= 0.0:
		return {"error": "stats.pipe_z must be > 0"}

	var vars_dict: Dictionary = data.get("vars", {})
	var valid_mod_stats: Array = vocab_affordances.get("modifiable_stats", [])
	var valid_phases: Array = vocab_affordances.get("modifier_phases", [])

	for mod in data.get("modifiers", []):
		if typeof(mod) != TYPE_DICTIONARY:
			return {"error": "modifier entry must be object"}
		if not valid_mod_stats.has(str(mod.get("stat", ""))):
			return {"error": "Unknown modifier stat '%s'" % str(mod.get("stat", ""))}
		if not valid_phases.has(str(mod.get("phase", ""))):
			return {"error": "Unknown modifier phase '%s'" % str(mod.get("phase", ""))}
		var e_err := _validate_expr_safety(str(mod.get("value", "")), stats, vars_dict)
		if e_err != "":
			return {"error": e_err}
		if mod.has("if"):
			var if_err := _validate_expr_safety(str(mod["if"]), stats, vars_dict)
			if if_err != "":
				return {"error": if_err}

	var valid_events: Array = vocab_events.get("events", [])
	for rx in data.get("reactions", []):
		if typeof(rx) != TYPE_DICTIONARY:
			return {"error": "reaction entry must be object"}
		var ev := str(rx.get("on", ""))
		if not valid_events.has(ev):
			return {"error": "Unknown reaction event '%s'" % ev}
		if rx.has("if"):
			var rx_if_err := _validate_expr_safety(str(rx["if"]), stats, vars_dict)
			if rx_if_err != "":
				return {"error": rx_if_err}
		var do_list: Variant = rx.get("do", [])
		if typeof(do_list) != TYPE_ARRAY or do_list.is_empty():
			return {"error": "reaction.do must be non-empty array"}
		for act_obj in do_list:
			if typeof(act_obj) != TYPE_DICTIONARY:
				return {"error": "action entry must be object"}
			var act_name := str(act_obj.get("act", ""))
			if not vocab_actions.has(act_name):
				return {"error": "Unknown action verb '%s'" % act_name}
			if act_name == "deal_damage" and ev == "on_damage_dealt":
				if str(rx.get("if", "")).find("ctx.is_secondary_damage") == -1:
					return {"error": "Law L8: unguarded deal_damage in on_damage_dealt causes infinite recursion"}
			if act_name == "var_add" or act_name == "var_set":
				var v_name := str(act_obj.get("var", ""))
				var v_err := _validate_var_target(v_name, vars_dict)
				if v_err != "":
					return {"error": v_err}
				var expr_field := "value" if act_name == "var_set" else "by"
				var ve := _validate_expr_safety(str(act_obj.get(expr_field, "")), stats, vars_dict)
				if ve != "":
					return {"error": ve}

	var valid_offline: Array = vocab_affordances.get("offline_modes", [])
	if not valid_offline.has(str(data.get("offline", "none"))):
		return {"error": "Unknown offline mode"}

	data["id"] = cap_id
	return {"data": data}


func _validate_references_and_economy(cap_id: String, data: Dictionary, known_ids: Dictionary, stage1: Dictionary) -> String:
	for rx in data.get("reactions", []):
		for act_obj in rx.get("do", []):
			var act_name := str(act_obj.get("act", ""))
			if act_name == "spawn_item" or act_name == "consume_item":
				var item_ref := str(act_obj.get("item", ""))
				if not known_ids.has(item_ref):
					return "Orphan item reference '%s'" % item_ref
			elif act_name == "transform_tile":
				var blk_ref := str(act_obj.get("block", ""))
				if not known_ids.has(blk_ref):
					return "Orphan block reference '%s'" % blk_ref
			elif act_name == "transmute_self":
				var into_ref := str(act_obj.get("into", ""))
				if not known_ids.has(into_ref):
					return "Orphan transmute reference '%s'" % into_ref

	var spawned_val_on_consume := 0.0
	for rx in data.get("reactions", []):
		if str(rx.get("on", "")) == "on_consume":
			for act_obj in rx.get("do", []):
				if str(act_obj.get("act", "")) == "spawn_item":
					var target_id := str(act_obj.get("item", ""))
					var qty := float(str(act_obj.get("qty", "1")))
					var target_cap: Dictionary = capsules.get(target_id, stage1.get(target_id, {}))
					var t_val := float(target_cap.get("stats", {}).get("base_value", 1.0))
					spawned_val_on_consume += qty * t_val

	for offer in data.get("offered_by", []):
		var vendor := str(offer.get("vendor", ""))
		if not known_ids.has(vendor):
			return "Orphan vendor reference '%s'" % vendor
		var price: Dictionary = offer.get("price", {})
		var cost_val := 0.0
		for curr_id in price.keys():
			if not known_ids.has(str(curr_id)):
				return "Orphan currency reference '%s'" % str(curr_id)
			var c_cap: Dictionary = capsules.get(str(curr_id), stage1.get(str(curr_id), {}))
			var c_val := float(c_cap.get("stats", {}).get("base_value", 1.0))
			cost_val += float(price[curr_id]) * c_val
		if cost_val > 0.0 and spawned_val_on_consume > cost_val:
			return "Law L11 Positive-Gain Arbitrage Loop detected (cost=%s, yield=%s)" % [str(cost_val), str(spawned_val_on_consume)]

	return ""


func _validate_var_target(v_name: String, local_vars: Dictionary) -> String:
	if v_name.begins_with("self."):
		var k := v_name.substr(5)
		if not local_vars.has(k):
			return "Undeclared self register '%s'" % v_name
		return ""
	elif v_name.begins_with("shared."):
		var k := v_name.substr(7)
		if not vocab_shared_vars.has(k):
			return "Undeclared shared register '%s'" % v_name
		return ""
	return "Invalid register prefix in '%s'" % v_name


func _validate_expr_safety(expr_str: String, local_stats: Dictionary, local_vars: Dictionary) -> String:
	if expr_str.strip_edges() == "":
		return "Empty expression"
	for bad in FORBIDDEN_EXPR_TOKENS:
		if expr_str.find(bad) != -1:
			return "Forbidden expression token '%s' in '%s'" % [bad, expr_str]
	if expr_str.find("tile.depth - tile.depth") != -1 or expr_str.find("self.wear - self.wear") != -1:
		return "Self-canceling zero denominator in '%s'" % expr_str

	# Verify any self.<key> or shared.<key> references inside expression
	var tokens := expr_str.replace("(", " ").replace(")", " ").replace(",", " ").split(" ", false)
	for tok in tokens:
		if tok.begins_with("self.stats."):
			var sk := tok.substr(11)
			if not local_stats.has(sk):
				return "Undeclared self.stats.%s" % sk
		elif tok.begins_with("self."):
			var vk := tok.substr(5)
			if not local_vars.has(vk) and not local_stats.has(vk):
				return "Undeclared self.%s" % vk
		elif tok.begins_with("shared."):
			var shk := tok.substr(7)
			if not vocab_shared_vars.has(shk):
				return "Undeclared shared.%s" % shk
	return ""


func _check_raw_json_hazards(raw: String) -> String:
	var rx_trailing := RegEx.new()
	rx_trailing.compile(",\\s*[\\]\\}]")
	if rx_trailing.search(raw) != null:
		return "Law L9: Trailing comma in JSON"

	# Check duplicate keys within each brace scope
	var scope_stack: Array[Dictionary] = [{}]
	var in_str := false
	var escaped := false
	var cur_token := ""
	for i in raw.length():
		var ch := raw[i]
		if in_str:
			if escaped:
				escaped = false
			elif ch == "\\":
				escaped = true
			elif ch == "\"":
				in_str = false
			else:
				cur_token += ch
		else:
			if ch == "\"":
				in_str = true
				cur_token = ""
			elif ch == "{":
				scope_stack.append({})
			elif ch == "}":
				if scope_stack.size() > 1:
					scope_stack.pop_back()
			elif ch == ":":
				if cur_token != "" and not scope_stack.is_empty():
					var top: Dictionary = scope_stack[scope_stack.size() - 1]
					if top.has(cur_token):
						return "Law L9: Duplicate JSON key '%s'" % cur_token
					top[cur_token] = true
					cur_token = ""
	return ""


func _load_json_dict(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var j := JSON.new()
	if j.parse(f.get_as_text()) != OK:
		return {}
	return j.data if typeof(j.data) == TYPE_DICTIONARY else {}
