class_name DevCalibrationWindow
extends Window
## Detachable Linux Dev Calibration, Construction Set & Beta Sandbox Suite (Section 9).
## Provides live spawn sliders, 2D Sheet (XxY) vs Vertical Slice (XxZ) preview,
## per-sheet clumping readout, DPI preset simulator, Beta Sandbox Grants, and Quarantine Inspector.

signal calibration_changed()
signal dpi_preset_selected(screen_w: int, screen_h: int, dpi: int)

var catalog: CatalogDB
var generator: Generator3D
var grid: GridManager
var view_vertical_slice: bool = false
var preview_z_layer: int = 25
var _preview_canvas: Control
var _capsule_picker: OptionButton
var _picker_ids: Array[String] = []


func setup(p_catalog: CatalogDB, p_generator: Generator3D, p_grid: GridManager) -> void:
	catalog = p_catalog
	generator = p_generator
	grid = p_grid
	title = "StrataPaper — Linux Construction Set, 3D Vein Calibration & Beta Sandbox"
	size = Vector2i(820, 740)
	unresizable = false
	_build_ui()


func _build_ui() -> void:
	var root_vbox := VBoxContainer.new()
	root_vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 10)
	add_child(root_vbox)

	# Row 1: DPI Simulator Presets + Slice Toggle + Instant Reset
	var top_bar := HBoxContainer.new()
	root_vbox.add_child(top_bar)

	var preset_btn := OptionButton.new()
	preset_btn.add_item("Linux Dev 1x (448x992 @ 96 DPI)")
	preset_btn.add_item("Pixel 8 Pro QHD+ 3x (1344x2992 @ 489 DPI)")
	preset_btn.add_item("Pixel 8 Pro FHD+ 2x (1008x2244 @ 367 DPI)")
	preset_btn.add_item("Standard 1080p 3x (1080x2400 @ 400 DPI)")
	preset_btn.item_selected.connect(_on_preset_selected)
	top_bar.add_child(preset_btn)

	var slice_btn := Button.new()
	slice_btn.text = "Toggle X×Y Sheet / X×Z Vertical Slice"
	slice_btn.pressed.connect(func() -> void:
		view_vertical_slice = not view_vertical_slice
		if _preview_canvas != null:
			_preview_canvas.queue_redraw()
	)
	top_bar.add_child(slice_btn)

	var reroll_btn := Button.new()
	reroll_btn.text = "Instant Re-Roll (<1ms)"
	reroll_btn.pressed.connect(func() -> void:
		generator.master_seed += 1
		generator._init_noises()
		grid.reset_quarry()
		calibration_changed.emit()
		if _preview_canvas != null:
			_preview_canvas.queue_redraw()
	)
	top_bar.add_child(reroll_btn)

	# Row 2: Beta Sandbox Bar (Instant Ore Grant, Depth Unlock, Capsule Spawner, Lost Cat Spawner)
	var sandbox_bar := HBoxContainer.new()
	root_vbox.add_child(sandbox_bar)

	var grant_ores_btn := Button.new()
	grant_ores_btn.text = "Sandbox: +500 All Ores & Z=1000"
	grant_ores_btn.pressed.connect(func() -> void:
		grid.player_max_depth = maxi(grid.player_max_depth, 1000)
		grid.rules.shared_registers["gold_earned_total"] = float(grid.rules.shared_registers.get("gold_earned_total", 0.0)) + 5000.0
		grid.rules.shared_registers["reputation_vayne"] = float(grid.rules.shared_registers.get("reputation_vayne", 0.0)) + 100.0
		for bid in catalog.block_ids_sorted:
			grid.grant_inventory_item(String(bid), 0, 500, "backpack")
			grid.grant_inventory_item(String(bid), 1, 200, "backpack")
		calibration_changed.emit()
	)
	sandbox_bar.add_child(grant_ores_btn)

	_capsule_picker = OptionButton.new()
	_capsule_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_picker_ids.clear()
	var all_cids := catalog.capsules.keys()
	all_cids.sort()
	for cid in all_cids:
		var c_str := str(cid)
		if c_str.begins_with("blocks/") or c_str.begins_with("biomes/") or c_str.begins_with("npcs/"):
			continue
		_picker_ids.append(c_str)
		var nm := str(catalog.capsules[c_str].get("meta", {}).get("name", c_str))
		_capsule_picker.add_item("%s (%s)" % [nm, c_str])
	sandbox_bar.add_child(_capsule_picker)

	var grant_cap_btn := Button.new()
	grant_cap_btn.text = "Grant Selected Capsule"
	grant_cap_btn.pressed.connect(func() -> void:
		var idx := _capsule_picker.selected
		if idx >= 0 and idx < _picker_ids.size():
			var cid := _picker_ids[idx]
			grid.buy_vendor_offer("", {"capsule_id": cid, "price": {}}, true)
			calibration_changed.emit()
	)
	sandbox_bar.add_child(grant_cap_btn)

	var cat_btn := Button.new()
	cat_btn.text = "Spawn Lost Cat (C3)"
	cat_btn.pressed.connect(func() -> void:
		grid.quest_lost_cat_active = true
		if grid.in_bounds(2, 2):
			grid.dynamic_entity_id[grid.idx_of(2, 2)] = GridManager.ENTITY_LOST_CAT
		calibration_changed.emit()
	)
	sandbox_bar.add_child(cat_btn)

	# Row 3: Resource Sliders + Clumping Diagnostics Table
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 240)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root_vbox.add_child(scroll)

	var rows_vbox := VBoxContainer.new()
	rows_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(rows_vbox)

	for bid in catalog.block_ids_sorted:
		var cap: Dictionary = catalog.capsules[bid]
		var st: Dictionary = cap.get("stats", {})
		var row := HBoxContainer.new()
		rows_vbox.add_child(row)

		var swatch := ColorRect.new()
		swatch.custom_minimum_size = Vector2(14, 14)
		swatch.color = _color_for_block(String(bid), str(st.get("fluid_type", "NONE")))
		row.add_child(swatch)

		var name_lbl := Label.new()
		name_lbl.custom_minimum_size = Vector2(210, 0)
		name_lbl.text = " %s (Z≥%d)" % [str(cap.get("meta", {}).get("name", bid)), int(st.get("z_unlock", 0))]
		row.add_child(name_lbl)

		var slider := HSlider.new()
		slider.min_value = 0.0
		slider.max_value = 0.80
		slider.step = 0.005
		slider.value = float(st.get("spawn_prob", 0.05))
		slider.custom_minimum_size = Vector2(180, 0)
		row.add_child(slider)

		var diag_lbl := Label.new()
		diag_lbl.text = "%.1f%%" % [slider.value * 100.0]
		row.add_child(diag_lbl)

		slider.value_changed.connect(func(v: float) -> void:
			generator.slider_overrides[bid] = v
			diag_lbl.text = "%.1f%%" % [v * 100.0]
			grid.reset_quarry()
			calibration_changed.emit()
			if _preview_canvas != null:
				_preview_canvas.queue_redraw()
		)

	# Row 4: Cross-Section Visualizer Canvas
	_preview_canvas = Control.new()
	_preview_canvas.custom_minimum_size = Vector2(0, 210)
	_preview_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_preview_canvas.draw.connect(_draw_cross_section)
	root_vbox.add_child(_preview_canvas)

	# Row 5: Quarantine & Capsule Status Footer
	var status_lbl := Label.new()
	status_lbl.text = "Loaded Capsules: %d | Quarantined: %d | Vendors: %d | Frozen Quarry: %d×%d" % [
		catalog.capsules.size(), catalog.quarantined.size(), catalog.vendor_catalog.size(), grid.cols, grid.rows
	]
	root_vbox.add_child(status_lbl)


func _on_preset_selected(idx: int) -> void:
	match idx:
		0: dpi_preset_selected.emit(448, 992, 96)
		1: dpi_preset_selected.emit(1344, 2992, 489)
		2: dpi_preset_selected.emit(1008, 2244, 367)
		3: dpi_preset_selected.emit(1080, 2400, 400)


func _draw_cross_section() -> void:
	if _preview_canvas == null:
		return
	var cell := 6.0
	var cols_draw := 60
	var rows_draw := 32
	for r in rows_draw:
		for c in cols_draw:
			var v: Dictionary
			if view_vertical_slice:
				v = generator.sample_voxel(c, 0, r * 15, 0.0, true)
			else:
				v = generator.sample_voxel(c, r, preview_z_layer, 0.0, true)
			var col := _color_for_block(str(v["solid_id"]), str(v["fluid_type"]))
			_preview_canvas.draw_rect(Rect2(c * cell, r * cell, cell - 1.0, cell - 1.0), col, true)


func _color_for_block(bid: String, fl_type: String) -> Color:
	if fl_type == "WATER":
		return Color(0.18, 0.52, 0.95)
	if fl_type == "LAVA":
		return Color(0.98, 0.35, 0.08)
	match bid:
		"blocks/dirt": return Color(0.48, 0.34, 0.22)
		"blocks/stone": return Color(0.42, 0.44, 0.48)
		"blocks/copper": return Color(0.85, 0.48, 0.20)
		"blocks/quartz_vein": return Color(0.82, 0.86, 0.92)
		"blocks/obsidian_hazard": return Color(0.22, 0.08, 0.35)
		_:
			var h := float(abs(bid.hash()) % 360) / 360.0
			var s := 0.38 + float((abs(bid.hash()) >> 8) % 30) / 100.0
			var v := 0.52 + float((abs(bid.hash()) >> 16) % 22) / 100.0
			return Color.from_hsv(h, s, v)
