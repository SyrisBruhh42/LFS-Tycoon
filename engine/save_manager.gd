class_name SaveManager
extends RefCounted
## Law L10: Reference-only instance serialization ({capsule_id, vars}), frozen quarry dimensions (D1),
## atomic write-temp-then-rename with 2 rolling backups, and dormant-stub preservation for unknown/quarantined capsules.

const SAVE_SCHEMA_VERSION: int = 1


static func serialize_state(grid: GridManager) -> Dictionary:
	var n := grid.cols * grid.rows
	var tiles_out: Array[Dictionary] = []
	tiles_out.resize(n)
	for i in n:
		var atts_out: Array[Dictionary] = []
		for inst in grid.tile_attachments[i]:
			if not bool(inst.get("destroyed", false)):
				# Law L10: Store only reference {capsule_id, vars, uid} — never copy static stats!
				atts_out.append({
					"uid": int(inst.get("uid", 0)),
					"capsule_id": str(inst.get("capsule_id", "")),
					"vars": inst.get("vars", {}).duplicate(true)
				})
		var cat_id_str := ""
		if grid.placed_catalyst_id[i] >= 0 and grid.placed_catalyst_id[i] < grid.catalog.block_int_to_id.size():
			cat_id_str = grid.catalog.block_int_to_id[grid.placed_catalyst_id[i]]
		tiles_out[i] = {
			"z": grid.depth[i],
			"max_z": grid.max_depth_reached[i],
			"block": grid.catalog.block_int_to_id[grid.base_id[i]],
			"tier": grid.tier[i],
			"dmg": snappedf(grid.damage_accum[i], 0.001),
			"hp": snappedf(grid.max_hp[i], 0.001),
			"fl_type": grid.fluid_type[i],
			"fl_lvl": grid.fluid_level[i],
			"cat_id": cat_id_str,
			"cat_tier": grid.placed_catalyst_tier[i],
			"atts": atts_out
		}

	var eq_out: Array[Dictionary] = []
	for inst in grid.player_equipped_items:
		if not bool(inst.get("destroyed", false)):
			eq_out.append({
				"uid": int(inst.get("uid", 0)),
				"capsule_id": str(inst.get("capsule_id", "")),
				"vars": inst.get("vars", {}).duplicate(true)
			})

	return {
		"save_schema": SAVE_SCHEMA_VERSION,
		"seed": grid.generator.master_seed,
		"frozen_cols": grid.cols,
		"frozen_rows": grid.rows,
		"player_max_depth": grid.player_max_depth,
		"player_grime": grid.player_grime,
		"player_is_rested": grid.player_is_rested,
		"inventory": grid.inventory.duplicate(true),
		"paired_chest_loot": grid.paired_chest_loot.duplicate(true),
		"shared_registers": grid.rules.shared_registers.duplicate(true),
		"ui_flags": grid.rules.ui_flags.duplicate(true),
		"equipped": eq_out,
		"tiles": tiles_out
	}


static func save_atomic(grid: GridManager, save_path: String = "user://quarry_save.json") -> bool:
	var payload := serialize_state(grid)
	var json_text := JSON.stringify(payload, "  ")
	var tmp_path := save_path + ".tmp"
	var bak1_path := save_path + ".bak1"
	var bak2_path := save_path + ".bak2"

	var f := FileAccess.open(tmp_path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(json_text)
	f.flush()
	f = null

	# Rotate rolling backups (.bak1 -> .bak2, current -> .bak1, .tmp -> current)
	var dir := DirAccess.open(save_path.get_base_dir())
	if dir == null:
		return false
	if FileAccess.file_exists(bak1_path):
		dir.rename(bak1_path.get_file(), bak2_path.get_file())
	if FileAccess.file_exists(save_path):
		dir.rename(save_path.get_file(), bak1_path.get_file())
	var err := dir.rename(tmp_path.get_file(), save_path.get_file())
	return err == OK


static func load_with_fallback(grid: GridManager, save_path: String = "user://quarry_save.json") -> Dictionary:
	for candidate in [save_path, save_path + ".bak1", save_path + ".bak2"]:
		if not FileAccess.file_exists(candidate):
			continue
		var f := FileAccess.open(candidate, FileAccess.READ)
		if f == null:
			continue
		var j := JSON.new()
		if j.parse(f.get_as_text()) == OK and typeof(j.data) == TYPE_DICTIONARY:
			var restored := restore_state(grid, j.data)
			restored["loaded_from"] = candidate
			return restored
	return {"ok": false, "error": "No valid save file found"}


static func restore_state(grid: GridManager, data: Dictionary) -> Dictionary:
	if int(data.get("save_schema", 0)) != SAVE_SCHEMA_VERSION:
		return {"ok": false, "error": "Unsupported save schema"}

	# Law D1: Restore frozen quarry dimensions from save
	var saved_cols := int(data.get("frozen_cols", grid.cols))
	var saved_rows := int(data.get("frozen_rows", grid.rows))
	if saved_cols != grid.cols or saved_rows != grid.rows:
		grid.cols = saved_cols
		grid.rows = saved_rows
		grid._allocate_buffers()

	grid.player_max_depth = int(data.get("player_max_depth", 0))
	grid.player_grime = float(data.get("player_grime", 0.0))
	grid.player_is_rested = bool(data.get("player_is_rested", true))
	grid.inventory = data.get("inventory", {}).duplicate(true)
	grid.paired_chest_loot = data.get("paired_chest_loot", {}).duplicate(true)

	var sr: Dictionary = data.get("shared_registers", {})
	for k in sr.keys():
		if grid.rules.shared_registers.has(k):
			grid.rules.shared_registers[k] = float(sr[k])

	var uf: Dictionary = data.get("ui_flags", {})
	for k in uf.keys():
		grid.rules.ui_flags[k] = bool(uf[k])

	var dormant_stubs := 0
	grid.player_equipped_items.clear()
	for eq in data.get("equipped", []):
		var cid := str(eq.get("capsule_id", ""))
		var is_dormant := not grid.catalog.capsules.has(cid) or grid.catalog.quarantined.has(cid)
		if is_dormant:
			dormant_stubs += 1
		grid.player_equipped_items.append({
			"uid": int(eq.get("uid", grid.next_instance_uid)),
			"capsule_id": cid,
			"vars": eq.get("vars", {}).duplicate(true),
			"destroyed": false,
			"dormant_stub": is_dormant
		})
		grid.next_instance_uid = maxi(grid.next_instance_uid, int(eq.get("uid", 0)) + 1)

	var tiles_in: Array = data.get("tiles", [])
	var n := mini(grid.cols * grid.rows, tiles_in.size())
	for i in n:
		var td: Dictionary = tiles_in[i]
		grid.depth[i] = int(td.get("z", 0))
		grid.max_depth_reached[i] = int(td.get("max_z", grid.depth[i]))
		var blk_str := str(td.get("block", "blocks/stone"))
		grid.base_id[i] = int(grid.catalog.block_id_to_int.get(blk_str, grid.catalog.block_id_to_int.get("blocks/stone", 0)))
		grid.tier[i] = int(td.get("tier", 0))
		grid.damage_accum[i] = float(td.get("dmg", 0.0))
		grid.max_hp[i] = maxf(1.0, float(td.get("hp", 10.0)))
		grid.fluid_type[i] = int(td.get("fl_type", 0))
		grid.fluid_level[i] = int(td.get("fl_lvl", 0))
		var cat_str := str(td.get("cat_id", ""))
		grid.placed_catalyst_id[i] = int(grid.catalog.block_id_to_int.get(cat_str, -1)) if cat_str != "" else -1
		grid.placed_catalyst_tier[i] = int(td.get("cat_tier", 0))

		grid.tile_attachments[i] = []
		for att in td.get("atts", []):
			var cid := str(att.get("capsule_id", ""))
			var is_dormant := not grid.catalog.capsules.has(cid) or grid.catalog.quarantined.has(cid)
			if is_dormant:
				dormant_stubs += 1
			grid.tile_attachments[i].append({
				"uid": int(att.get("uid", grid.next_instance_uid)),
				"capsule_id": cid,
				"vars": att.get("vars", {}).duplicate(true),
				"destroyed": false,
				"dormant_stub": is_dormant
			})
			grid.next_instance_uid = maxi(grid.next_instance_uid, int(att.get("uid", 0)) + 1)

	return {"ok": true, "dormant_stubs_preserved": dormant_stubs}
