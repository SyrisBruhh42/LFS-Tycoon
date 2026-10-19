class_name MainQuarry
extends Node2D
## Main 2D Top-Down Layered 3D Quarry Canvas (Single-pass _draw() batch renderer).
## Renders tiles, persistent crack stages, fluid overlays, hazard perimeters, placed capsules,
## micro-font Z depth counters, and progressive diegetic HUD instruments (Chalk, Chess-Grid, Loupe).

var catalog: CatalogDB
var generator: Generator3D
var rules: RuleEngine
var grid: GridManager
var active_tool: Dictionary = {}
var dev_window: DevCalibrationWindow = null

var _holding_press: bool = false
var _press_screen_pos: Vector2 = Vector2.ZERO
var _hovered_tile: Vector2i = Vector2i(0, 0)
var _elapsed_time: float = 0.0


func _ready() -> void:
	catalog = CatalogDB.new()
	catalog.load_all("res://content/capsules")
	generator = Generator3D.new(catalog, 1337)
	rules = RuleEngine.new(catalog, 1337)
	grid = GridManager.new(catalog, generator, rules)

	# Equip starter Crude Stone Pickaxe
	active_tool = grid.create_capsule_instance("tools/crude_stone_pick")
	grid.player_equipped_items.append(active_tool)

	# Apply initial viewport integer scaling
	var vp_size := get_viewport_rect().size
	var dpi := DisplayServer.screen_get_dpi() if DisplayServer.get_name() != "headless" else 96
	if dpi <= 0:
		dpi = 96
	grid.apply_viewport_scaling(int(vp_size.x), int(vp_size.y), dpi)

	# Spawn detachable Linux Dev Calibration Window when running with a desktop display
	if DisplayServer.get_name() != "headless" and (OS.has_feature("editor") or OS.get_name() == "Linux"):
		dev_window = DevCalibrationWindow.new()
		dev_window.setup(catalog, generator, grid)
		dev_window.calibration_changed.connect(queue_redraw)
		dev_window.dpi_preset_selected.connect(func(w: int, h: int, d: int) -> void:
			grid.apply_viewport_scaling(w, h, d)
			queue_redraw()
		)
		add_child(dev_window)
		dev_window.show()


func _physics_process(delta: float) -> void:
	_elapsed_time += delta
	if _holding_press:
		var drifted := grid.apply_drunk_touch_offset(_press_screen_pos, _elapsed_time)
		var world_pt := drifted + grid.pan_offset_px
		var tx := int(floor(world_pt.x / float(grid.tile_size_px)))
		var ty := int(floor(world_pt.y / float(grid.tile_size_px)))
		if grid.in_bounds(tx, ty):
			_hovered_tile = Vector2i(tx, ty)
			grid.apply_mining_tick(tx, ty, active_tool, delta, true)
	grid.step_physics(delta)
	queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_holding_press = mb.pressed
			_press_screen_pos = mb.position
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		_press_screen_pos = mm.position


func _draw() -> void:
	var t_px := float(grid.tile_size_px)
	var show_chalk := bool(rules.ui_flags.get("hud_chalk_lines", false))
	var show_chess := bool(rules.ui_flags.get("hud_chess_grid", false))
	var show_loupe := bool(rules.ui_flags.get("hud_target_loupe", false))
	var font := ThemeDB.fallback_font

	for y in grid.rows:
		for x in grid.cols:
			var i := grid.idx_of(x, y)
			var rx := float(x) * t_px - grid.pan_offset_px.x
			var ry := float(y) * t_px - grid.pan_offset_px.y
			var rect := Rect2(rx, ry, t_px, t_px)

			var bid_str := catalog.block_int_to_id[grid.base_id[i]]
			var col := _get_tile_color(bid_str, grid.fluid_type[i], grid.tier[i])
			draw_rect(rect, col, true)

			# Persistent damage ratio bar / crack indicator
			if grid.damage_accum[i] > 0.0:
				var dmg_ratio := clampf(grid.damage_accum[i] / maxf(1.0, grid.max_hp[i]), 0.0, 1.0)
				draw_rect(Rect2(rx + 2.0, ry + t_px - 5.0, (t_px - 4.0) * dmg_ratio, 3.0), Color(1.0, 0.85, 0.2), true)

			# Chalk lines upgrade
			var border_col := Color(0.85, 0.88, 0.92, 0.35) if show_chalk else Color(0.08, 0.09, 0.11, 0.65)
			draw_rect(rect, border_col, false, 1.0)

			# Crisp micro-font Z depth counter on tile
			if font != null:
				draw_string(
					font,
					Vector2(rx + 3.0, ry + 11.0),
					str(grid.depth[i]),
					HORIZONTAL_ALIGNMENT_LEFT,
					-1,
					maxi(8, 9 * grid.scale_k / 2),
					Color(0.92, 0.94, 0.98, 0.85)
				)

	# Surveyor's Chess-Grid upgrade (A1-N31)
	if show_chess and font != null:
		for x in grid.cols:
			var col_letter := String.chr(65 + x)
			draw_string(font, Vector2(float(x) * t_px + t_px * 0.35, 12.0), col_letter, HORIZONTAL_ALIGNMENT_CENTER, -1, 10, Color(1, 0.9, 0.4))

	# Floating Target Loupe upgrade
	if show_loupe and font != null and grid.in_bounds(_hovered_tile.x, _hovered_tile.y):
		var hi := grid.idx_of(_hovered_tile.x, _hovered_tile.y)
		var b_name := str(catalog.capsules.get(catalog.block_int_to_id[grid.base_id[hi]], {}).get("meta", {}).get("name", "Block"))
		var coord_str := "%s%d" % [String.chr(65 + _hovered_tile.x), _hovered_tile.y + 1]
		var loupe_txt := "[%s] %s (T%d) | Z:%d | HP: %.1f/%.1f" % [
			coord_str, b_name, grid.tier[hi], grid.depth[hi],
			maxf(0.0, grid.max_hp[hi] - grid.damage_accum[hi]), grid.max_hp[hi]
		]
		draw_rect(Rect2(6, 4, 340, 22), Color(0.05, 0.07, 0.10, 0.88), true)
		draw_string(font, Vector2(12, 19), loupe_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.95, 0.98, 1.0))


func _get_tile_color(bid: String, fl_type: int, tier_val: int) -> Color:
	if fl_type == GridManager.FLUID_WATER:
		return Color(0.15, 0.48, 0.92)
	if fl_type == GridManager.FLUID_LAVA:
		return Color(0.95, 0.32, 0.08)
	var base_c := Color(0.42, 0.44, 0.48)
	match bid:
		"blocks/dirt": base_c = Color(0.46, 0.33, 0.21)
		"blocks/copper": base_c = Color(0.82, 0.46, 0.20)
		"blocks/obsidian_hazard": base_c = Color(0.20, 0.07, 0.32)
	return base_c.darkened(minf(0.45, float(tier_val) * 0.12))
