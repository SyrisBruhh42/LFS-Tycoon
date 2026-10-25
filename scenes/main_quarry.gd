class_name MainQuarry
extends Node2D
## Main 2D Top-Down Layered 3D Quarry Canvas & Playable Beta UI Controller.
## Renders tiles, persistent crack stages, fluid overlays, hazard perimeters, placed capsules,
## micro-font Z depth counters, diegetic HUD instruments, and slide-up Bag/Shop/Homestead drawers.

enum CursorMode {
	MINE,
	SCOOP,
	PLACE,
	BACKFILL,
	CATALYST,
	PAN
}

## HUD metrics are LOGICAL units; the HUD CanvasLayer is scaled by grid.scale_k (same dpi density mechanism as the world tiles).
const TOP_HUD_H: float = 96.0
const BOTTOM_DOCK_H: float = 112.0
## Minimum touch target (Android guideline 48dp), in logical units.
const MIN_TOUCH: float = 48.0

var catalog: CatalogDB
var generator: Generator3D
var rules: RuleEngine
var grid: GridManager
var active_tool: Dictionary = {}
var fallback_bucket_tool: Dictionary = {}
var selected_place_inst: Dictionary = {}
var dev_window: DevCalibrationWindow = null
## >0 forces the density used for world+HUD scaling (tests/ui_audit.gd simulates a 489 dpi phone).
var forced_dpi: int = 0

var cursor_mode: int = CursorMode.MINE
var active_drawer: String = "" # "", "bag", "forge", "shop", "homestead"
var shop_vendor_filter: String = "ALL"
var shop_category_filter: String = "ALL"
var shop_search_query: String = ""
var shop_page_offset: int = 0
var forge_discipline_filter: String = "ALL"
var forge_page_offset: int = 0
const SHOP_PAGE_SIZE: int = 25

var _holding_press: bool = false
var _panning_drag: bool = false
var _press_screen_pos: Vector2 = Vector2.ZERO
var _hovered_tile: Vector2i = Vector2i(0, 0)
var _selected_tile: Vector2i = Vector2i(0, 0)
var _elapsed_time: float = 0.0
var _status_toast: String = "Welcome to StrataPaper Beta! Hold-click tiles to excavate."
var _last_alert_count: int = 0

# UI Layer nodes
var _hud_layer: CanvasLayer
var _hud_root: Control
var _drawer_scroll: ScrollContainer
var _last_drawer_kind: String = ""
var _ui_k: int = 1
var _lbl_top_stats: Label
var _lbl_tile_info: Label
var _lbl_toast: Label
var _mode_buttons: Dictionary = {}
var _tab_buttons: Dictionary = {}
var _drawer_panel: PanelContainer
var _drawer_title: Label
var _drawer_body: VBoxContainer


func _ready() -> void:
	catalog = CatalogDB.new()
	catalog.load_all("res://content/capsules")
	generator = Generator3D.new(catalog, 1337)
	rules = RuleEngine.new(catalog, 1337)
	grid = GridManager.new(catalog, generator, rules)

	_init_starter_loadout()

	# Auto-load existing save if available
	if FileAccess.file_exists("user://quarry_save.json"):
		var l_res := SaveManager.load_with_fallback(grid, "user://quarry_save.json")
		if bool(l_res.get("ok", false)):
			if not grid.player_tool.is_empty():
				active_tool = grid.player_tool
			_status_toast = "Loaded saved quarry (%d capsules active)." % catalog.capsules.size()

	var vp_size := get_viewport_rect().size if is_inside_tree() else Vector2(1080, 2400)
	var dpi := DisplayServer.screen_get_dpi() if DisplayServer.get_name() != "headless" else 96
	if forced_dpi > 0:
		dpi = forced_dpi
	if dpi <= 0:
		dpi = 96
	grid.apply_viewport_scaling(int(vp_size.x), int(vp_size.y), dpi)

	_build_hud()
	_refresh_hud_labels()

	# Spawn detachable Linux Dev Calibration Window when running with a desktop display
	if DisplayServer.get_name() != "headless" and (OS.has_feature("editor") or OS.get_name() == "Linux"):
		dev_window = DevCalibrationWindow.new()
		dev_window.setup(catalog, generator, grid)
		dev_window.calibration_changed.connect(func() -> void:
			_refresh_drawer()
			_refresh_hud_labels()
			queue_redraw()
		)
		dev_window.dpi_preset_selected.connect(func(w: int, h: int, d: int) -> void:
			grid.apply_viewport_scaling(w, h, d)
			queue_redraw()
		)
		add_child(dev_window)
		dev_window.show()


func _init_starter_loadout() -> void:
	active_tool = grid.create_capsule_instance("tools/crude_stone_pick")
	grid.equip_tool_instance(active_tool)
	grid.player_owned_capsules.append(active_tool)

	# Provide a synthetic starter bail bucket so the player can always scoop early water/lava
	if not catalog.capsules.has("tools/starter_bail_bucket"):
		catalog.capsules["tools/starter_bail_bucket"] = {
			"schema": 1,
			"meta": {"name": "Wooden Bail Bucket", "description": "Starter bucket for scooping water and lava pockets.", "rarity": "common"},
			"affordances": ["carry", "equip_tool"],
			"tags": ["tool", "bucket"],
			"stats": {"tool_type": "BUCKET", "tool_tier": 1, "base_dps": 120.0},
			"vars": {},
			"modifiers": [],
			"reactions": []
		}
	fallback_bucket_tool = grid.create_capsule_instance("tools/starter_bail_bucket")
	grid.player_owned_capsules.append(fallback_bucket_tool)

	# Starter backfill dirt & copper catalysts for immediate testing
	grid.grant_inventory_item("blocks/dirt", 0, 15, "backpack")
	grid.grant_inventory_item("blocks/copper", 0, 10, "backpack")


func _physics_process(delta: float) -> void:
	_elapsed_time += delta
	if _holding_press and active_drawer == "":
		if cursor_mode == CursorMode.MINE or cursor_mode == CursorMode.SCOOP:
			var tile_pt := _screen_to_tile(_press_screen_pos, true)
			if grid.in_bounds(tile_pt.x, tile_pt.y):
				_hovered_tile = tile_pt
				_selected_tile = tile_pt
				var i := grid.idx_of(tile_pt.x, tile_pt.y)
				var tool_to_use := active_tool
				if cursor_mode == CursorMode.SCOOP or (grid.fluid_level[i] > 0 and _get_tool_type(active_tool) != "BUCKET"):
					if cursor_mode == CursorMode.SCOOP:
						tool_to_use = _find_best_bucket_tool()
				var res := grid.apply_mining_tick(tile_pt.x, tile_pt.y, tool_to_use, delta, true)
				if bool(res.get("stalled", false)) and grid.fluid_level[i] > 0:
					_status_toast = "Flooded tile! Switch to [Scoop] mode or equip a Bucket."
				elif bool(res.get("stalled", false)):
					_status_toast = "Strict-locked hazard! Surround its 8-perimeter with [Catalyst] blocks at equal Z."

	grid.step_physics(delta)
	if rules.alerts_emitted.size() > _last_alert_count:
		var latest: Dictionary = rules.alerts_emitted[rules.alerts_emitted.size() - 1]
		_status_toast = "Alert [%s]: %s (%s)" % [str(latest.get("channel", "")), str(latest.get("tag", "")), str(latest.get("capsule_id", ""))]
		_last_alert_count = rules.alerts_emitted.size()

	_refresh_hud_labels()
	queue_redraw()


func _get_tool_type(t_inst: Dictionary) -> String:
	var cid := str(t_inst.get("capsule_id", ""))
	return str(catalog.capsules.get(cid, {}).get("stats", {}).get("tool_type", "PICKAXE"))


func _find_best_bucket_tool() -> Dictionary:
	if _get_tool_type(active_tool) == "BUCKET":
		return active_tool
	for inst in grid.player_owned_capsules:
		if not bool(inst.get("destroyed", false)) and _get_tool_type(inst) == "BUCKET":
			return inst
	return fallback_bucket_tool


func _screen_to_tile(screen_pos: Vector2, apply_drift: bool = false) -> Vector2i:
	var p := grid.apply_drunk_touch_offset(screen_pos, _elapsed_time) if apply_drift else screen_pos
	var world_pt := Vector2(p.x + grid.pan_offset_px.x, p.y - _top_px() + grid.pan_offset_px.y)
	var tx := int(floor(world_pt.x / float(grid.tile_size_px)))
	var ty := int(floor(world_pt.y / float(grid.tile_size_px)))
	return Vector2i(tx, ty)


## Which layer owns pointer input right now: an open drawer owns ALL of it; otherwise the quarry owns the middle band.
func _input_owner() -> String:
	return "drawer" if active_drawer != "" else "world"


## True when a screen-y falls in the quarry band (between the top HUD and the bottom dock).
func _is_world_y(y: float, vp_h: float) -> bool:
	return y >= _top_px() and y <= vp_h - _bottom_px()


func _unhandled_input(event: InputEvent) -> void:
	if _input_owner() == "drawer":
		return
	var vp_h := get_viewport_rect().size.y
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if not _is_world_y(mb.position.y, vp_h):
			_holding_press = false
			_panning_drag = false
			return
		if mb.button_index == MOUSE_BUTTON_RIGHT or mb.button_index == MOUSE_BUTTON_MIDDLE:
			_panning_drag = mb.pressed
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_press_screen_pos = mb.position
			if cursor_mode == CursorMode.PAN:
				_panning_drag = mb.pressed
				_holding_press = false
			elif mb.pressed:
				var pt := _screen_to_tile(mb.position, true)
				if grid.in_bounds(pt.x, pt.y):
					_hovered_tile = pt
					_selected_tile = pt
					_on_tile_primary_press(pt.x, pt.y)
				if cursor_mode == CursorMode.MINE or cursor_mode == CursorMode.SCOOP:
					_holding_press = true
			else:
				_holding_press = false
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		_press_screen_pos = mm.position
		if _panning_drag:
			var vp_size := get_viewport_rect().size
			var avail_h := maxf(100.0, vp_size.y - _top_px() - _bottom_px())
			var max_px := maxf(0.0, float(grid.cols * grid.tile_size_px) - vp_size.x)
			var max_py := maxf(0.0, float(grid.rows * grid.tile_size_px) - avail_h)
			grid.pan_offset_px.x = clampf(grid.pan_offset_px.x - mm.relative.x, 0.0, max_px)
			grid.pan_offset_px.y = clampf(grid.pan_offset_px.y - mm.relative.y, 0.0, max_py)
		else:
			var pt := _screen_to_tile(mm.position, false)
			if grid.in_bounds(pt.x, pt.y):
				_hovered_tile = pt


func _on_tile_primary_press(tx: int, ty: int) -> void:
	var i := grid.idx_of(tx, ty)
	grid.tap_tile(tx, ty, active_tool)

	# Check Lost Cat interaction
	if grid.dynamic_entity_id[i] == GridManager.ENTITY_LOST_CAT:
		if _get_tool_type(active_tool) == "CAPTURE_NET":
			grid.dynamic_entity_id[i] = GridManager.ENTITY_NONE
			rules.shared_registers["gold_earned_total"] = float(rules.shared_registers.get("gold_earned_total", 0.0)) + 250.0
			rules.shared_registers["reputation_vayne"] = float(rules.shared_registers.get("reputation_vayne", 0.0)) + 5.0
			_status_toast = "Captured the Lost Cat with a Capture Net! +250 Gold & +5 Vayne Rep!"
			return

	if cursor_mode == CursorMode.MINE:
		var h_info := grid.get_hazard_cluster_and_perimeter(tx, ty)
		if bool(h_info.get("ready_to_detonate", false)):
			var det := grid.try_detonate_hazard_at(tx, ty)
			if bool(det.get("detonated", false)):
				_status_toast = "BOOM! Shattered %d Obsidian Hazard block(s)!" % int(det.get("shattered_count", 1))
				return
	elif cursor_mode == CursorMode.PLACE:
		if selected_place_inst.is_empty() or bool(selected_place_inst.get("destroyed", false)):
			_status_toast = "Select a placeable device/carpet/auto-tool in [Bag & Gear] first."
			return
		if not grid.tile_attachments[i].has(selected_place_inst):
			grid.attach_capsule_to_tile(tx, ty, selected_place_inst)
			var nm := str(catalog.capsules.get(str(selected_place_inst.get("capsule_id", "")), {}).get("meta", {}).get("name", "Item"))
			_status_toast = "Placed %s on tile (%d, %d)." % [nm, tx, ty]
	elif cursor_mode == CursorMode.BACKFILL:
		var mat := "blocks/dirt"
		if grid.can_satisfy_requirement("blocks/dirt", 0, 1):
			grid.action_consume_item("blocks/dirt", 0, 1)
			mat = "blocks/dirt"
		elif grid.can_satisfy_requirement("blocks/stone", 0, 1):
			grid.action_consume_item("blocks/stone", 0, 1)
			mat = "blocks/stone"
		else:
			_status_toast = "Need 1 Dirt or Stone in Bag to backfill."
			return
		if grid.apply_backfill(tx, ty, mat):
			_status_toast = "Backfilled tile (%d, %d) to Z=%d." % [tx, ty, grid.depth[i]]
		else:
			grid.grant_inventory_item(mat, 0, 1, "backpack")
			_status_toast = "Tile (%d, %d) is already at surface Z=0." % [tx, ty]
	elif cursor_mode == CursorMode.CATALYST:
		var best_cat := _find_catalyst_in_inventory()
		if best_cat.is_empty():
			_status_toast = "Need Copper or a catalyst block in Bag to prime hazard perimeters."
			return
		var c_id := str(best_cat["id"])
		var c_tier := int(best_cat["tier"])
		if grid.action_consume_item(c_id, c_tier, 1):
			grid.place_catalyst_on_tile(tx, ty, c_id, c_tier)
			_status_toast = "Placed T%d %s catalyst at (%d, %d) Z=%d." % [c_tier, c_id.get_file(), tx, ty, grid.depth[i]]
			# Check if any adjacent hazard cluster is now ready to detonate!
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					if grid.in_bounds(tx + dx, ty + dy):
						var det := grid.try_detonate_hazard_at(tx + dx, ty + dy)
						if bool(det.get("detonated", false)):
							_status_toast = "DETONATED %d Hazard Block(s) via perimeter catalysts!" % int(det.get("shattered_count", 1))
							return


func _find_catalyst_in_inventory() -> Dictionary:
	var best_id := ""
	var best_tier := -1
	for k in grid.inventory.keys():
		var ks := str(k)
		if int(grid.inventory[ks]) <= 0:
			continue
		var parts := ks.split(":")
		if parts.size() != 2:
			continue
		var cid := parts[0]
		var t_val := int(parts[1])
		var affs: Array = catalog.capsules.get(cid, {}).get("affordances", [])
		if affs.has("catalyst") or cid == "blocks/copper":
			if t_val > best_tier:
				best_tier = t_val
				best_id = cid
	if best_id == "":
		return {}
	return {"id": best_id, "tier": best_tier}


func _top_px() -> float:
	return TOP_HUD_H * float(_ui_k)


func _bottom_px() -> float:
	return BOTTOM_DOCK_H * float(_ui_k)


func _opaque_style(c: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = c
	sb.content_margin_left = 8.0
	sb.content_margin_right = 8.0
	sb.content_margin_top = 4.0
	sb.content_margin_bottom = 4.0
	return sb


## Scales the HUD by the same density factor as the world and sizes its logical root to viewport / k.
## (Anchors under a scaled CanvasLayer resolve against the UNscaled viewport, so a sized root Control is required.)
func _apply_ui_scale() -> void:
	_ui_k = maxi(1, grid.scale_k)
	var vp: Vector2 = get_viewport_rect().size if is_inside_tree() else Vector2(448, 992)
	if _hud_layer != null:
		_hud_layer.scale = Vector2(_ui_k, _ui_k)
	if _hud_root != null:
		_hud_root.position = Vector2.ZERO
		_hud_root.size = vp / float(_ui_k)


## Touch-first normalisation: no sticky keyboard focus rings, >=48 logical-unit targets, truncating (never overflowing) text.
func _touchify(n: Node, wrap_labels: bool = false) -> void:
	if n is Button:
		var b := n as Button
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size.y = maxf(b.custom_minimum_size.y, MIN_TOUCH)
		b.custom_minimum_size.x = maxf(b.custom_minimum_size.x, MIN_TOUCH)
		if b is OptionButton:
			b.clip_text = true
	elif wrap_labels and n is Label:
		var l := n as Label
		if l.autowrap_mode == TextServer.AUTOWRAP_OFF:
			l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size.x = maxf(l.custom_minimum_size.x, 60.0)
	for c in n.get_children():
		_touchify(c, wrap_labels)


## Shared touch-first button look: visible affordance for normal/hover/pressed/disabled (default theme is dark-on-dark).
func _build_ui_theme() -> Theme:
	var th := Theme.new()
	var states := {
		"normal": Color(0.20, 0.23, 0.31),
		"hover": Color(0.26, 0.30, 0.40),
		"pressed": Color(0.30, 0.46, 0.38),
		"disabled": Color(0.13, 0.14, 0.18),
	}
	for st in states.keys():
		var sb := StyleBoxFlat.new()
		sb.bg_color = states[st]
		sb.set_corner_radius_all(6)
		sb.content_margin_left = 10.0
		sb.content_margin_right = 10.0
		sb.content_margin_top = 6.0
		sb.content_margin_bottom = 6.0
		if st == "disabled":
			sb.set_border_width_all(1)
			sb.border_color = Color(0.26, 0.28, 0.34)
		th.set_stylebox(st, "Button", sb)
		th.set_stylebox(st, "OptionButton", sb)
	th.set_color("font_disabled_color", "Button", Color(0.55, 0.57, 0.64))
	th.set_color("font_color", "Button", Color(0.94, 0.96, 1.0))
	return th


func _restore_scroll(v: int) -> void:
	if not is_inside_tree():
		return
	await get_tree().process_frame
	if _drawer_scroll != null and is_instance_valid(_drawer_scroll):
		_drawer_scroll.scroll_vertical = v


func _build_hud() -> void:
	_hud_layer = CanvasLayer.new()
	add_child(_hud_layer)
	_hud_root = Control.new()
	_hud_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_root.theme = _build_ui_theme()
	_hud_layer.add_child(_hud_root)
	_apply_ui_scale()
	if is_inside_tree():
		get_viewport().size_changed.connect(_apply_ui_scale)

	# 1. Top Telemetry Bar (opaque so the world never bleeds through text)
	var top_panel := PanelContainer.new()
	top_panel.add_theme_stylebox_override("panel", _opaque_style(Color(0.10, 0.11, 0.14)))
	top_panel.set_anchors_preset(Control.PRESET_TOP_WIDE)
	top_panel.offset_bottom = TOP_HUD_H
	_hud_root.add_child(top_panel)

	var top_vbox := VBoxContainer.new()
	top_vbox.add_theme_constant_override("separation", 2)
	top_panel.add_child(top_vbox)

	var top_row := HBoxContainer.new()
	top_vbox.add_child(top_row)

	_lbl_top_stats = Label.new()
	_lbl_top_stats.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lbl_top_stats.custom_minimum_size.x = 40.0
	_lbl_top_stats.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_lbl_top_stats.add_theme_font_size_override("font_size", 14)
	_lbl_top_stats.add_theme_color_override("font_color", Color(0.95, 0.92, 0.72))
	top_row.add_child(_lbl_top_stats)

	var hot_btn := Button.new()
	hot_btn.text = "⬇ Update"
	hot_btn.add_theme_font_size_override("font_size", 13)
	hot_btn.custom_minimum_size.x = 96.0
	hot_btn.pressed.connect(func() -> void:
		_on_hot_update_pressed()
	)
	top_row.add_child(hot_btn)

	_lbl_tile_info = Label.new()
	_lbl_tile_info.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_lbl_tile_info.add_theme_font_size_override("font_size", 12)
	_lbl_tile_info.add_theme_color_override("font_color", Color(0.82, 0.92, 0.98))
	top_vbox.add_child(_lbl_tile_info)

	_lbl_toast = Label.new()
	_lbl_toast.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_lbl_toast.add_theme_font_size_override("font_size", 12)
	_lbl_toast.add_theme_color_override("font_color", Color(0.58, 0.95, 0.68))
	top_vbox.add_child(_lbl_toast)

	# 2. Slide-Up Drawer Panel (hidden when active_drawer == ""). Opaque: focus belongs to the drawer while open.
	_drawer_panel = PanelContainer.new()
	_drawer_panel.add_theme_stylebox_override("panel", _opaque_style(Color(0.085, 0.095, 0.125)))
	_drawer_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_drawer_panel.offset_top = TOP_HUD_H
	_drawer_panel.offset_bottom = -BOTTOM_DOCK_H
	_drawer_panel.visible = false
	_hud_root.add_child(_drawer_panel)

	var drawer_outer := VBoxContainer.new()
	_drawer_panel.add_child(drawer_outer)

	var header_bar := HBoxContainer.new()
	drawer_outer.add_child(header_bar)

	_drawer_title = Label.new()
	_drawer_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_drawer_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_drawer_title.add_theme_font_size_override("font_size", 16)
	_drawer_title.add_theme_color_override("font_color", Color(1.0, 0.90, 0.55))
	header_bar.add_child(_drawer_title)

	var close_btn := Button.new()
	close_btn.text = "✕ Close"
	close_btn.pressed.connect(func() -> void:
		_set_active_drawer("")
	)
	header_bar.add_child(close_btn)

	var drawer_scroll := ScrollContainer.new()
	drawer_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	drawer_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	drawer_outer.add_child(drawer_scroll)
	_drawer_scroll = drawer_scroll

	_drawer_body = VBoxContainer.new()
	_drawer_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_drawer_body.add_theme_constant_override("separation", 8)
	drawer_scroll.add_child(_drawer_body)

	# 3. Bottom Control Dock (Cursor Modes + Navigation Tabs)
	var bottom_panel := PanelContainer.new()
	bottom_panel.add_theme_stylebox_override("panel", _opaque_style(Color(0.10, 0.11, 0.14)))
	bottom_panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bottom_panel.offset_top = -BOTTOM_DOCK_H
	_hud_root.add_child(bottom_panel)

	var dock_vbox := VBoxContainer.new()
	dock_vbox.add_theme_constant_override("separation", 4)
	bottom_panel.add_child(dock_vbox)

	var mode_row := HBoxContainer.new()
	mode_row.alignment = BoxContainer.ALIGNMENT_CENTER
	dock_vbox.add_child(mode_row)

	var mode_specs := [
		[CursorMode.MINE, "Mine"],
		[CursorMode.SCOOP, "Scoop"],
		[CursorMode.PLACE, "Place"],
		[CursorMode.BACKFILL, "Fill"],
		[CursorMode.CATALYST, "Cat."],
		[CursorMode.PAN, "Pan"]
	]
	for ms in mode_specs:
		var m_val: int = ms[0]
		var m_txt: String = ms[1]
		var b := Button.new()
		b.text = m_txt
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", 13)
		b.pressed.connect(func() -> void:
			cursor_mode = m_val
			_set_active_drawer("")
			_update_dock_button_highlights()
		)
		mode_row.add_child(b)
		_mode_buttons[m_val] = b

	var tab_row := HBoxContainer.new()
	tab_row.alignment = BoxContainer.ALIGNMENT_CENTER
	dock_vbox.add_child(tab_row)

	var tab_specs := [
		["", "Quarry"],
		["bag", "Bag"],
		["forge", "⚒ Forge"],
		["shop", "Shop"],
		["homestead", "Home"]
	]
	for ts in tab_specs:
		var t_id: String = ts[0]
		var t_txt: String = ts[1]
		var tb := Button.new()
		tb.text = t_txt
		tb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tb.add_theme_font_size_override("font_size", 13)
		tb.pressed.connect(func() -> void:
			if t_id != "" and active_drawer == t_id:
				_set_active_drawer("")
			else:
				_set_active_drawer(t_id)
		)
		tab_row.add_child(tb)
		_tab_buttons[t_id] = tb

	_touchify(_hud_root)
	_update_dock_button_highlights()


func _on_hot_update_pressed() -> void:
	var res := grid.hot_reload_catalog()
	var added_cnt := int(res.get("added_count", 0))
	var total_cnt := int(res.get("total_capsules", catalog.capsules.size()))
	if added_cnt > 0:
		_status_toast = "Hot-Update applied! +%d new capsule(s) live (%d total)." % [added_cnt, total_cnt]
	else:
		_status_toast = "Catalog up-to-date (%d capsules active, 0 new deltas)." % total_cnt
	_refresh_drawer()
	_refresh_hud_labels()
	queue_redraw()


func _update_dock_button_highlights() -> void:
	for m_key in _mode_buttons.keys():
		var b: Button = _mode_buttons[m_key]
		b.modulate = Color(1.0, 0.92, 0.45) if int(m_key) == cursor_mode else Color(0.85, 0.85, 0.88)
	for t_key in _tab_buttons.keys():
		var tb: Button = _tab_buttons[t_key]
		tb.modulate = Color(0.55, 0.95, 0.72) if str(t_key) == active_drawer else Color(0.85, 0.85, 0.88)


func _set_active_drawer(drawer_name: String) -> void:
	active_drawer = drawer_name
	_holding_press = false
	_panning_drag = false
	_drawer_panel.visible = (active_drawer != "")
	_update_dock_button_highlights()
	if active_drawer != "":
		_refresh_drawer()


func _refresh_hud_labels() -> void:
	if _lbl_top_stats == null:
		return
	var gold := int(round(float(rules.shared_registers.get("gold_earned_total", 0.0))))
	var rest_str := "Rested" if grid.player_is_rested else "Tired"
	_lbl_top_stats.text = "Z %d · %dg · Grime %.0f · %s · %d caps" % [
		grid.player_max_depth, gold, grid.player_grime, rest_str, catalog.capsules.size()
	]

	var t_cid := str(active_tool.get("capsule_id", ""))
	var t_name := str(catalog.capsules.get(t_cid, {}).get("meta", {}).get("name", "Bare Hands"))
	var tv: Dictionary = active_tool.get("vars", {})
	var dur_txt := ""
	if tv.has("durability_left"):
		dur_txt += " Dur:%.0f" % float(tv["durability_left"])
	if tv.has("charge_left"):
		dur_txt += " Chg:%.0fs" % float(tv["charge_left"])

	if grid.in_bounds(_hovered_tile.x, _hovered_tile.y):
		var hi := grid.idx_of(_hovered_tile.x, _hovered_tile.y)
		var b_id := catalog.block_int_to_id[grid.base_id[hi]]
		var b_name := str(catalog.capsules.get(b_id, {}).get("meta", {}).get("name", b_id))
		var coord := "%s%d" % [String.chr(65 + _hovered_tile.x), _hovered_tile.y + 1]
		var fl_txt := ""
		if grid.fluid_level[hi] > 0:
			fl_txt = " [WATER x%d]" % grid.fluid_level[hi] if grid.fluid_type[hi] == GridManager.FLUID_WATER else " [LAVA x%d]" % grid.fluid_level[hi]
		var att_cnt: int = grid.tile_attachments[hi].size()
		var att_txt := (" [+%d dev]" % att_cnt) if att_cnt > 0 else ""
		_lbl_tile_info.text = "%s%s · [%s] %s T%d · Z%d · HP %.0f/%.0f%s%s" % [
			t_name, dur_txt, coord, b_name, grid.tier[hi], grid.depth[hi],
			maxf(0.0, grid.max_hp[hi] - grid.damage_accum[hi]), grid.max_hp[hi], fl_txt, att_txt
		]
	_lbl_toast.text = " > " + _status_toast


func _refresh_drawer() -> void:
	if _drawer_body == null:
		return
	var keep_scroll := 0
	if _drawer_scroll != null and _last_drawer_kind == active_drawer:
		keep_scroll = _drawer_scroll.scroll_vertical
	_last_drawer_kind = active_drawer
	for ch in _drawer_body.get_children():
		_drawer_body.remove_child(ch)
		ch.queue_free()

	if active_drawer == "bag":
		_build_bag_drawer()
	elif active_drawer == "forge":
		_build_forge_drawer()
	elif active_drawer == "shop":
		_build_shop_drawer()
	elif active_drawer == "homestead" or active_drawer == "home":
		_build_homestead_drawer()
	_touchify(_drawer_body, true)
	if keep_scroll > 0:
		_restore_scroll(keep_scroll)


func _build_bag_drawer() -> void:
	_drawer_title.text = "BAG & LOADOUT"

	# Section A: Mined Ores in Backpack
	var ore_hdr := Label.new()
	ore_hdr.text = "--- Mined Blocks & Ores (Backpack) ---"
	ore_hdr.add_theme_color_override("font_color", Color(0.95, 0.85, 0.50))
	_drawer_body.add_child(ore_hdr)

	if grid.inventory.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = "  (No mined blocks yet — hold-click tiles on the Quarry to mine!)"
		_drawer_body.add_child(empty_lbl)
	else:
		var keys := grid.inventory.keys()
		keys.sort()
		for k in keys:
			var ks := str(k)
			var qty := int(grid.inventory.get(ks, 0))
			if qty <= 0:
				continue
			var parts := ks.split(":")
			var bid := parts[0]
			var tier_v := int(parts[1]) if parts.size() > 1 else 0
			var bname := str(catalog.capsules.get(bid, {}).get("meta", {}).get("name", bid))
			var row := HBoxContainer.new()
			_drawer_body.add_child(row)
			var lbl := Label.new()
			lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			lbl.text = "  %s (Tier %d)  x%d" % [bname, tier_v, qty]
			row.add_child(lbl)
			var sell_btn := Button.new()
			sell_btn.text = "Sell All"
			sell_btn.pressed.connect(func() -> void:
				var g := grid.sell_to_market(bid, tier_v, qty)
				_status_toast = "Sold %d %s (T%d) for %d Gold!" % [qty, bname, tier_v, g]
				_refresh_drawer()
				_refresh_hud_labels()
			)
			row.add_child(sell_btn)

	# Section B: Owned Tools, Devices, Books, Consumables & Perks
	var gear_hdr := Label.new()
	gear_hdr.text = "\n--- Owned Capsules (Tools, Gadgets, Books, Tonics, Perks) ---"
	gear_hdr.add_theme_color_override("font_color", Color(0.70, 0.95, 0.85))
	_drawer_body.add_child(gear_hdr)

	grid._prune_player_items()
	for inst in grid.player_owned_capsules:
		var cid := str(inst.get("capsule_id", ""))
		var cap: Dictionary = catalog.capsules.get(cid, {})
		if cap.is_empty():
			continue
		var nm := str(cap.get("meta", {}).get("name", cid))
		var desc := str(cap.get("meta", {}).get("description", ""))
		var affs: Array = cap.get("affordances", [])

		var card := VBoxContainer.new()
		_drawer_body.add_child(card)

		var top_row := HFlowContainer.new()

		var is_active_tool: bool = (active_tool == inst)
		var is_eq_buff: bool = grid.player_equipped_items.has(inst)
		var is_sel_place: bool = (selected_place_inst == inst)
		var badge := ""
		if is_active_tool:
			badge = " [ACTIVE TOOL]"
		elif is_sel_place:
			badge = " [SELECTED TO PLACE]"
		elif is_eq_buff:
			badge = " [EQUIPPED / ACTIVE]"

		var title_lbl := Label.new()
		title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		title_lbl.text = "• %s%s" % [nm, badge]
		title_lbl.add_theme_color_override("font_color", Color(0.95, 0.98, 1.0))
		title_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		card.add_child(title_lbl)
		card.add_child(top_row)

		if affs.has("equip_tool"):
			var eq_btn := Button.new()
			eq_btn.text = "Equipped" if is_active_tool else "Equip Tool"
			eq_btn.disabled = is_active_tool
			eq_btn.pressed.connect(func() -> void:
				active_tool = inst
				grid.equip_tool_instance(inst)
				_status_toast = "Equipped %s." % nm
				_refresh_drawer()
				_refresh_hud_labels()
			)
			top_row.add_child(eq_btn)

		if affs.has("place_on_tile"):
			var pl_btn := Button.new()
			pl_btn.text = "Place on Tile"
			pl_btn.pressed.connect(func() -> void:
				selected_place_inst = inst
				cursor_mode = CursorMode.PLACE
				_status_toast = "Tap any Quarry tile to place %s." % nm
				_set_active_drawer("")
			)
			top_row.add_child(pl_btn)

		if affs.has("socket_in_tool"):
			var sk_btn := Button.new()
			sk_btn.text = "Socket in Tool"
			sk_btn.pressed.connect(func() -> void:
				if grid.socket_capsule_into_tool(inst, active_tool):
					_status_toast = "Socketed %s into active tool!" % nm
					_refresh_drawer()
			)
			top_row.add_child(sk_btn)

		if affs.has("consume") or affs.has("read_book"):
			var use_btn := Button.new()
			use_btn.text = "Read" if affs.has("read_book") else "Consume"
			use_btn.pressed.connect(func() -> void:
				if grid.consume_capsule(inst):
					_status_toast = "Used %s!" % nm
					_refresh_drawer()
					_refresh_hud_labels()
			)
			top_row.add_child(use_btn)

		if (affs.has("carry") or affs.has("place_in_house")) and not affs.has("equip_tool"):
			var toggle_btn := Button.new()
			toggle_btn.text = "Unequip" if is_eq_buff else "Activate"
			toggle_btn.pressed.connect(func() -> void:
				if is_eq_buff:
					grid.unequip_item(inst)
					_status_toast = "Unequipped %s." % nm
				else:
					grid.equip_item(inst)
					_status_toast = "Activated %s." % nm
				_refresh_drawer()
			)
			top_row.add_child(toggle_btn)

		if desc != "":
			var d_lbl := Label.new()
			d_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			d_lbl.add_theme_font_size_override("font_size", 12)
			d_lbl.add_theme_color_override("font_color", Color(0.72, 0.76, 0.82))
			d_lbl.text = "    " + desc
			card.add_child(d_lbl)


func _reason_label(txt: String) -> Label:
	var why := Label.new()
	why.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	why.custom_minimum_size.x = 80.0
	why.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	why.size_flags_stretch_ratio = 1.6
	why.add_theme_font_size_override("font_size", 12)
	why.add_theme_color_override("font_color", Color(0.95, 0.72, 0.55))
	why.text = txt
	return why


func _build_shop_drawer() -> void:
	_drawer_title.text = "SHOP (%d vendors)" % catalog.vendor_catalog.size()

	# Filter Row 1: Vendor Selector + Category Selector
	var filter_row := VBoxContainer.new()
	_drawer_body.add_child(filter_row)

	var v_opt := OptionButton.new()
	v_opt.clip_text = true
	v_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var vendor_ids: Array[String] = ["ALL"]
	v_opt.add_item("All Vendors (%d)" % catalog.vendor_catalog.size())
	var sorted_vendors := catalog.vendor_catalog.keys()
	sorted_vendors.sort()
	for vid in sorted_vendors:
		var v_str := str(vid)
		vendor_ids.append(v_str)
		var v_name := str(catalog.capsules.get(v_str, {}).get("meta", {}).get("name", v_str))
		var req_z := grid.get_vendor_unlock_depth(v_str)
		var count: int = catalog.vendor_catalog[v_str].size()
		v_opt.add_item("%s (Z≥%d) [%d]" % [v_name, req_z, count])
		if v_str == shop_vendor_filter:
			v_opt.selected = vendor_ids.size() - 1
	v_opt.item_selected.connect(func(idx: int) -> void:
		shop_vendor_filter = vendor_ids[clampi(idx, 0, vendor_ids.size() - 1)]
		shop_page_offset = 0
		_refresh_drawer()
	)
	filter_row.add_child(v_opt)

	var c_opt := OptionButton.new()
	c_opt.clip_text = true
	var cats := ["ALL", "tools", "devices", "upgrades", "consumables", "books", "textiles"]
	for c_idx in cats.size():
		c_opt.add_item("Cat: " + cats[c_idx].capitalize())
		if cats[c_idx] == shop_category_filter:
			c_opt.selected = c_idx
	c_opt.item_selected.connect(func(idx: int) -> void:
		shop_category_filter = cats[clampi(idx, 0, cats.size() - 1)]
		shop_page_offset = 0
		_refresh_drawer()
	)
	filter_row.add_child(c_opt)

	# Filter Row 2: Search Box
	var search_row := HBoxContainer.new()
	_drawer_body.add_child(search_row)
	var search_box := LineEdit.new()
	search_box.placeholder_text = "Search name, tag or friction…"
	search_box.text = shop_search_query
	search_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search_box.text_submitted.connect(func(new_txt: String) -> void:
		shop_search_query = new_txt.strip_edges().to_lower()
		shop_page_offset = 0
		_refresh_drawer()
	)
	search_row.add_child(search_box)

	var find_btn := Button.new()
	find_btn.text = "Filter"
	find_btn.pressed.connect(func() -> void:
		shop_search_query = search_box.text.strip_edges().to_lower()
		shop_page_offset = 0
		_refresh_drawer()
	)
	search_row.add_child(find_btn)

	# Gather matching offers
	var matching_offers: Array[Dictionary] = []
	for vid in sorted_vendors:
		var v_str := str(vid)
		if shop_vendor_filter != "ALL" and v_str != shop_vendor_filter:
			continue
		for offer in catalog.vendor_catalog[v_str]:
			var cid := str(offer.get("capsule_id", ""))
			var ns := cid.split("/")[0] if cid.find("/") != -1 else ""
			if shop_category_filter != "ALL" and ns != shop_category_filter:
				continue
			var cap: Dictionary = catalog.capsules.get(cid, {})
			var nm := str(cap.get("meta", {}).get("name", cid))
			var desc := str(cap.get("meta", {}).get("description", ""))
			var tags_str := " ".join(PackedStringArray(cap.get("tags", [])))
			if shop_search_query != "":
				var hay := (cid + " " + nm + " " + desc + " " + tags_str).to_lower()
				if hay.find(shop_search_query) == -1:
					continue
			matching_offers.append({"vendor_id": v_str, "offer": offer, "name": nm, "desc": desc, "cid": cid})

	# Pagination Header
	var total_matches := matching_offers.size()
	var page_row := HBoxContainer.new()
	_drawer_body.add_child(page_row)
	var page_lbl := Label.new()
	page_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var start_i := mini(shop_page_offset, maxi(0, total_matches - 1))
	var end_i := mini(start_i + SHOP_PAGE_SIZE, total_matches)
	page_lbl.text = "Showing %d-%d of %d offers" % [start_i + 1 if total_matches > 0 else 0, end_i, total_matches]
	page_row.add_child(page_lbl)

	var show_pager := total_matches > SHOP_PAGE_SIZE
	var prev_btn := Button.new()
	prev_btn.text = "< Prev"
	prev_btn.disabled = (shop_page_offset <= 0)
	prev_btn.pressed.connect(func() -> void:
		shop_page_offset = maxi(0, shop_page_offset - SHOP_PAGE_SIZE)
		_refresh_drawer()
	)
	if show_pager:
		page_row.add_child(prev_btn)

	var next_btn := Button.new()
	next_btn.text = "Next >"
	next_btn.disabled = (end_i >= total_matches)
	next_btn.pressed.connect(func() -> void:
		shop_page_offset = end_i
		_refresh_drawer()
	)
	if show_pager:
		page_row.add_child(next_btn)

	for idx in range(start_i, end_i):
		var entry: Dictionary = matching_offers[idx]
		var v_id := str(entry["vendor_id"])
		var offer: Dictionary = entry["offer"]
		var nm := str(entry["name"])
		var desc := str(entry["desc"])
		var chk := grid.can_buy_vendor_offer(v_id, offer)
		var can_buy := bool(chk.get("can_buy", false))

		var price_parts: Array[String] = []
		var price_dict: Dictionary = offer.get("price", {})
		for curr_id in price_dict.keys():
			var c_nm := str(catalog.capsules.get(str(curr_id), {}).get("meta", {}).get("name", str(curr_id).get_file()))
			price_parts.append("%d %s" % [int(price_dict[curr_id]), c_nm])
		var price_str := ", ".join(PackedStringArray(price_parts))

		var item_box := VBoxContainer.new()
		_drawer_body.add_child(item_box)

		var lbl := Label.new()
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.text = "%s — Cost: %s" % [nm, price_str]
		lbl.add_theme_color_override("font_color", Color(0.95, 0.96, 1.0) if can_buy else Color(0.65, 0.65, 0.70))
		item_box.add_child(lbl)

		var r1 := HBoxContainer.new()
		item_box.add_child(r1)

		var buy_btn := Button.new()
		buy_btn.text = "Buy" if can_buy else "Locked"
		buy_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		buy_btn.disabled = not can_buy
		buy_btn.pressed.connect(func() -> void:
			var res := grid.buy_vendor_offer(v_id, offer, false)
			if bool(res.get("ok", false)):
				_status_toast = "Purchased %s! Check [Bag & Gear]." % nm
				_refresh_drawer()
				_refresh_hud_labels()
		)
		r1.add_child(buy_btn)
		if not can_buy:
			r1.add_child(_reason_label(str(chk.get("reason", "Locked"))))

		var d_lbl := Label.new()
		d_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		d_lbl.add_theme_font_size_override("font_size", 12)
		d_lbl.add_theme_color_override("font_color", Color(0.70, 0.75, 0.82))
		d_lbl.text = "   " + desc
		item_box.add_child(d_lbl)


func _build_forge_drawer() -> void:
	_drawer_title.text = "⚒ FORGE & SKILL BRACKETS"

	var unlocked_skills: Array[String] = []
	for inst in grid.player_owned_capsules:
		if bool(inst.get("destroyed", false)):
			continue
		var cid := str(inst.get("capsule_id", ""))
		if grid.is_permanent_prerequisite(cid):
			var s_nm := str(catalog.capsules.get(cid, {}).get("meta", {}).get("name", cid))
			if not unlocked_skills.has(s_nm):
				unlocked_skills.append(s_nm)

	var sub_lbl := Label.new()
	sub_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sub_lbl.add_theme_font_size_override("font_size", 12)
	sub_lbl.add_theme_color_override("font_color", Color(0.78, 0.90, 0.98))
	var skill_summary := "None yet (Unlock in Discipline 7 / 9!)" if unlocked_skills.is_empty() else ", ".join(PackedStringArray(unlocked_skills.slice(0, 5)))
	sub_lbl.text = "Active Skill Brackets & Stations (%d): %s\n(Skill Brackets & Stations are verified and KEPT permanently when forging; base tools transfer socketed Tinker parts!)" % [
		unlocked_skills.size(), skill_summary
	]
	_drawer_body.add_child(sub_lbl)

	var disc_specs := [
		["ALL", "All Forge & Multi-Reagent Recipes"],
		["craft_tinker_part", "1. Tinker Modular Part Forging (Socketable Heads/Rods/Bindings)"],
		["craft_terraria_fusion", "2. Terraria Cumulative Item Fusion (Consumes Base Gear + Ores)"],
		["craft_skyrim_enchant", "3. Skyrim Arcane Enchanting & Resonance Sigils"],
		["craft_alchemy_potion", "4. Multi-Reagent Alchemy & Decoctions"],
		["craft_spell_grimoire", "5. Quarry Geomancy Spells & Grimoires"],
		["craft_smeltery_alloy", "6. Smeltery Alloying & Crucible Transmutation"],
		["craft_skill_mastery", "7. Expandable Modular Skill Brackets & Guild Masteries"],
		["craft_achievement_relic", "8. Quarry Achievement Seals & Milestone Trophies"],
		["craft_homestead_station", "9. Homestead Workshop Benches & Stations"],
		["craft_clockwork_automaton", "10. Clockwork Automatons & Autonomous Field Rigs"]
	]

	var filter_row := HBoxContainer.new()
	_drawer_body.add_child(filter_row)

	var d_opt := OptionButton.new()
	d_opt.clip_text = true
	d_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for d_idx in disc_specs.size():
		var spec_entry: Array = disc_specs[d_idx]
		d_opt.add_item(str(spec_entry[1]))
		if str(spec_entry[0]) == forge_discipline_filter:
			d_opt.selected = d_idx
	d_opt.item_selected.connect(func(idx: int) -> void:
		var clamped := clampi(idx, 0, disc_specs.size() - 1)
		forge_discipline_filter = str(disc_specs[clamped][0])
		forge_page_offset = 0
		_refresh_drawer()
	)
	filter_row.add_child(d_opt)

	var sorted_vendors := catalog.vendor_catalog.keys()
	sorted_vendors.sort()
	var forge_entries: Array[Dictionary] = []
	var fallback_entries: Array[Dictionary] = []

	for vid in sorted_vendors:
		var v_str := str(vid)
		var offers_arr: Array = catalog.vendor_catalog[v_str]
		for offer_var in offers_arr:
			var offer: Dictionary = offer_var
			var cid := str(offer.get("capsule_id", ""))
			var cap: Dictionary = catalog.capsules.get(cid, {})
			if cap.is_empty():
				continue
			var tags_arr: Array = cap.get("tags", [])
			var price_dict: Dictionary = offer.get("price", {})
			var has_craft_tag := false
			for t_var in tags_arr:
				var ts := str(t_var)
				if ts.begins_with("craft_") or ts == "skill_bracket" or ts.begins_with("skill_school_"):
					has_craft_tag = true
					break
			var has_item_reagent := false
			for p_key in price_dict.keys():
				if not str(p_key).begins_with("blocks/"):
					has_item_reagent = true
					break
			var is_multi_ing := price_dict.size() >= 2

			var entry_dict := {
				"vendor_id": v_str,
				"offer": offer,
				"cid": cid,
				"name": str(cap.get("meta", {}).get("name", cid)),
				"desc": str(cap.get("meta", {}).get("description", "")),
				"tags": tags_arr
			}
			if forge_discipline_filter != "ALL":
				if tags_arr.has(forge_discipline_filter):
					forge_entries.append(entry_dict)
				elif forge_discipline_filter == "craft_terraria_fusion" and has_item_reagent:
					forge_entries.append(entry_dict)
				elif forge_discipline_filter == "craft_tinker_part" and cap.get("affordances", []).has("socket_in_tool"):
					forge_entries.append(entry_dict)
				elif forge_discipline_filter == "craft_alchemy_potion" and cid.begins_with("consumables/"):
					forge_entries.append(entry_dict)
				elif forge_discipline_filter == "craft_spell_grimoire" and cid.begins_with("books/"):
					forge_entries.append(entry_dict)
				elif forge_discipline_filter == "craft_skill_mastery" and (cid.begins_with("upgrades/") or tags_arr.has("skill_bracket")):
					forge_entries.append(entry_dict)
				elif forge_discipline_filter == "craft_homestead_station" and cap.get("affordances", []).has("place_in_house"):
					forge_entries.append(entry_dict)
				elif forge_discipline_filter == "craft_clockwork_automaton" and cap.get("affordances", []).has("place_on_tile"):
					forge_entries.append(entry_dict)
			else:
				if has_craft_tag or has_item_reagent or is_multi_ing:
					forge_entries.append(entry_dict)
				else:
					fallback_entries.append(entry_dict)

	if forge_entries.is_empty() and forge_discipline_filter == "ALL":
		forge_entries = fallback_entries

	var total_matches := forge_entries.size()
	var page_row := HBoxContainer.new()
	_drawer_body.add_child(page_row)
	var page_lbl := Label.new()
	page_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var start_i := mini(forge_page_offset, maxi(0, total_matches - 1))
	var end_i := mini(start_i + SHOP_PAGE_SIZE, total_matches)
	page_lbl.text = "Showing %d-%d of %d forgeable recipes" % [start_i + 1 if total_matches > 0 else 0, end_i, total_matches]
	page_row.add_child(page_lbl)

	var show_pager := total_matches > SHOP_PAGE_SIZE
	var prev_btn := Button.new()
	prev_btn.text = "< Prev"
	prev_btn.disabled = (forge_page_offset <= 0)
	prev_btn.pressed.connect(func() -> void:
		forge_page_offset = maxi(0, forge_page_offset - SHOP_PAGE_SIZE)
		_refresh_drawer()
	)
	if show_pager:
		page_row.add_child(prev_btn)

	var next_btn := Button.new()
	next_btn.text = "Next >"
	next_btn.disabled = (end_i >= total_matches)
	next_btn.pressed.connect(func() -> void:
		forge_page_offset = end_i
		_refresh_drawer()
	)
	if show_pager:
		page_row.add_child(next_btn)

	for idx in range(start_i, end_i):
		var entry: Dictionary = forge_entries[idx]
		var v_id := str(entry["vendor_id"])
		var offer: Dictionary = entry["offer"]
		var nm := str(entry["name"])
		var desc := str(entry["desc"])
		var tags_arr: Array = entry["tags"]
		var chk := grid.can_buy_vendor_offer(v_id, offer)
		var can_forge := bool(chk.get("can_buy", false))

		var logic_badge := "[CANONICAL]"
		if tags_arr.has("logic_absurd"):
			logic_badge = "[MUNCHKIN-ABSURD]"
		elif tags_arr.has("logic_whimsical"):
			logic_badge = "[WHIMSICAL]"
		elif tags_arr.has("logic_plausible"):
			logic_badge = "[PLAUSIBLE]"

		var bracket_badge := ""
		var theme_badge := ""
		for t_var in tags_arr:
			var ts := str(t_var)
			if ts.begins_with("bracket_"):
				bracket_badge = " [B" + ts.substr(8) + "]"
			elif ts.begins_with("theme_"):
				theme_badge = " [" + ts.substr(6) + "]"

		var kept_parts: Array[String] = []
		var consumed_parts: Array[String] = []
		var price_dict: Dictionary = offer.get("price", {})
		for curr_id in price_dict.keys():
			var c_str := str(curr_id)
			var req_q := int(price_dict[curr_id])
			var have_q := grid.get_owned_count(c_str, 0)
			var c_nm := str(catalog.capsules.get(c_str, {}).get("meta", {}).get("name", c_str.get_file()))
			var mark := "✓" if have_q >= req_q else "✗"
			if grid.is_permanent_prerequisite(c_str):
				kept_parts.append("%s %s (Skill/Station Kept)" % [mark, c_nm])
			else:
				consumed_parts.append("%s %s (%d/%d)" % [mark, c_nm, have_q, req_q])
		var recipe_segments: Array[String] = []
		if not kept_parts.is_empty():
			recipe_segments.append("Requires: " + ", ".join(PackedStringArray(kept_parts)))
		if not consumed_parts.is_empty():
			recipe_segments.append("Consumes: " + " + ".join(PackedStringArray(consumed_parts)))
		var recipe_str := "  |  ".join(PackedStringArray(recipe_segments))
		var v_name := str(catalog.capsules.get(v_id, {}).get("meta", {}).get("name", v_id.get_file()))

		var item_box := VBoxContainer.new()
		_drawer_body.add_child(item_box)

		var lbl := Label.new()
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.text = "%s%s%s %s — Artisan: %s" % [logic_badge, bracket_badge, theme_badge, nm, v_name]
		lbl.add_theme_color_override("font_color", Color(0.98, 0.92, 0.65) if can_forge else Color(0.68, 0.70, 0.75))
		item_box.add_child(lbl)

		var r1 := HBoxContainer.new()
		item_box.add_child(r1)

		var forge_btn := Button.new()
		forge_btn.text = "⚒ Forge" if can_forge else "Locked"
		forge_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		forge_btn.disabled = not can_forge
		forge_btn.pressed.connect(func() -> void:
			var res := grid.buy_vendor_offer(v_id, offer, false)
			if bool(res.get("ok", false)):
				var new_inst: Dictionary = res.get("instance", {})
				var inherited_cnt: int = new_inst.get("sockets", []).size()
				var inh_txt := (" (Inherited %d socketed part(s)!)" % inherited_cnt) if inherited_cnt > 0 else ""
				_status_toast = "Forged %s!%s Check [Bag & Gear]." % [nm, inh_txt]
				_refresh_drawer()
				_refresh_hud_labels()
		)
		r1.add_child(forge_btn)
		if not can_forge:
			r1.add_child(_reason_label(str(chk.get("reason", "Locked"))))

		var rec_lbl := Label.new()
		rec_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		rec_lbl.add_theme_font_size_override("font_size", 12)
		rec_lbl.add_theme_color_override("font_color", Color(0.62, 0.92, 0.75) if can_forge else Color(0.85, 0.68, 0.62))
		rec_lbl.text = "   " + recipe_str
		item_box.add_child(rec_lbl)

		var d_lbl := Label.new()
		d_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		d_lbl.add_theme_font_size_override("font_size", 12)
		d_lbl.add_theme_color_override("font_color", Color(0.70, 0.75, 0.82))
		d_lbl.text = "   " + desc
		item_box.add_child(d_lbl)


func _build_homestead_drawer() -> void:
	_drawer_title.text = "HOMESTEAD"

	var chest_count := 0
	for k in grid.paired_chest_loot.keys():
		chest_count += int(grid.paired_chest_loot[k])

	var btn_chest := Button.new()
	btn_chest.text = "Claim Chest Loot (%d waiting)" % chest_count
	btn_chest.pressed.connect(func() -> void:
		var claimed := grid.claim_paired_chest()
		_status_toast = "Claimed %d item(s) from Paired Chest into Bag!" % claimed
		_refresh_drawer()
		_refresh_hud_labels()
	)
	_drawer_body.add_child(btn_chest)

	var btn_sell_all := Button.new()
	btn_sell_all.text = "Sell All Ores to Market"
	btn_sell_all.pressed.connect(func() -> void:
		var gold := grid.sell_all_inventory_ores()
		_status_toast = "Sold all mined ores for +%d Gold!" % gold
		_refresh_drawer()
		_refresh_hud_labels()
	)
	_drawer_body.add_child(btn_sell_all)

	var btn_wash := Button.new()
	btn_wash.text = "Wash Off Grime (%.0f)" % grid.player_grime
	btn_wash.pressed.connect(func() -> void:
		grid.wash_grime()
		_status_toast = "Washed clean! Grime reset to 0."
		_refresh_drawer()
		_refresh_hud_labels()
	)
	_drawer_body.add_child(btn_wash)

	var btn_sleep := Button.new()
	btn_sleep.text = "Sleep (Restore Rested Perk)"
	btn_sleep.pressed.connect(func() -> void:
		grid.enter_house()
		grid.sleep_in_house()
		_status_toast = "Rested in Homestead! Rested buffs active."
		_refresh_drawer()
		_refresh_hud_labels()
	)
	_drawer_body.add_child(btn_sleep)

	var btn_offline := Button.new()
	btn_offline.text = "Offline Catch-Up (+1 Hour)"
	btn_offline.pressed.connect(func() -> void:
		var sim := OfflineSim.simulate_offline(grid, 3600.0)
		_status_toast = "Offline 1h Catch-Up: %d blocks mined (%.1f ms)!" % [
			int(sim.get("blocks_mined", 0)), float(sim.get("elapsed_ms", 0.0))
		]
		_refresh_drawer()
		_refresh_hud_labels()
		queue_redraw()
	)
	_drawer_body.add_child(btn_offline)

	var btn_hotpatch := Button.new()
	btn_hotpatch.text = "⬇ Hot-Update Capsules"
	btn_hotpatch.pressed.connect(func() -> void:
		_on_hot_update_pressed()
	)
	_drawer_body.add_child(btn_hotpatch)

	var save_row := HBoxContainer.new()
	_drawer_body.add_child(save_row)

	var btn_save := Button.new()
	btn_save.text = "Save Game"
	btn_save.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_save.pressed.connect(func() -> void:
		if SaveManager.save_atomic(grid, "user://quarry_save.json"):
			_status_toast = "Saved quarry & loadout to user://quarry_save.json."
	)
	save_row.add_child(btn_save)

	var btn_load := Button.new()
	btn_load.text = "Load Game"
	btn_load.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_load.pressed.connect(func() -> void:
		var res := SaveManager.load_with_fallback(grid, "user://quarry_save.json")
		if bool(res.get("ok", false)):
			if not grid.player_tool.is_empty():
				active_tool = grid.player_tool
			_status_toast = "Loaded save from %s." % str(res.get("loaded_from", "disk"))
			_refresh_drawer()
			_refresh_hud_labels()
			queue_redraw()
	)
	save_row.add_child(btn_load)


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
			var ry := _top_px() + float(y) * t_px - grid.pan_offset_px.y
			var rect := Rect2(rx, ry, t_px, t_px)

			var bid_str := catalog.block_int_to_id[grid.base_id[i]]
			var col := _get_tile_color(bid_str, grid.fluid_type[i], grid.tier[i])
			draw_rect(rect, col, true)

			# Persistent damage ratio bar / crack indicator
			if grid.damage_accum[i] > 0.0:
				var dmg_ratio := clampf(grid.damage_accum[i] / maxf(1.0, grid.max_hp[i]), 0.0, 1.0)
				draw_rect(Rect2(rx + 2.0, ry + t_px - 5.0, (t_px - 4.0) * dmg_ratio, 3.0), Color(1.0, 0.85, 0.2), true)

			# Hazard border vs chalk/standard grid border
			var blk_st: Dictionary = catalog.capsules.get(bid_str, {}).get("stats", {})
			var is_haz := int(blk_st.get("is_hazard", 0)) == 1
			var border_col := Color(0.95, 0.22, 0.55, 0.90) if is_haz else (Color(0.85, 0.88, 0.92, 0.35) if show_chalk else Color(0.08, 0.09, 0.11, 0.65))
			draw_rect(rect, border_col, false, 2.0 if is_haz else 1.0)

			# Selected / hovered tile outline
			if _hovered_tile.x == x and _hovered_tile.y == y:
				draw_rect(Rect2(rx + 1.0, ry + 1.0, t_px - 2.0, t_px - 2.0), Color(1.0, 0.95, 0.45, 0.85), false, 1.5)

			if font != null:
				var f_sz := maxi(8, 9 * grid.scale_k / 2)
				# Top-left: Z depth counter
				draw_string(
					font,
					Vector2(rx + 3.0, ry + 11.0),
					str(grid.depth[i]),
					HORIZONTAL_ALIGNMENT_LEFT,
					-1,
					f_sz,
					Color(0.92, 0.94, 0.98, 0.85)
				)
				# Bottom-right: Fluid level badge, Catalyst badge, or Attachment badge
				if grid.fluid_level[i] > 0:
					var fl_tag := ("W%d" if grid.fluid_type[i] == GridManager.FLUID_WATER else "L%d") % grid.fluid_level[i]
					draw_string(font, Vector2(rx + 3.0, ry + t_px - 7.0), fl_tag, HORIZONTAL_ALIGNMENT_LEFT, -1, f_sz, Color(0.95, 0.98, 1.0))
				elif grid.placed_catalyst_id[i] >= 0:
					draw_string(font, Vector2(rx + 3.0, ry + t_px - 7.0), "C%d" % grid.placed_catalyst_tier[i], HORIZONTAL_ALIGNMENT_LEFT, -1, f_sz, Color(0.35, 0.98, 0.95))
				if not grid.tile_attachments[i].is_empty():
					draw_rect(Rect2(rx + t_px - 8.0, ry + 3.0, 5.0, 5.0), Color(0.35, 0.95, 0.45), true)
				if grid.dynamic_entity_id[i] == GridManager.ENTITY_LOST_CAT:
					draw_string(font, Vector2(rx + 2.0, ry + t_px * 0.6), "CAT!", HORIZONTAL_ALIGNMENT_LEFT, -1, f_sz, Color(1.0, 0.92, 0.25))

	# Surveyor's Chess-Grid upgrade (A1-N31)
	if show_chess and font != null:
		for x in grid.cols:
			var col_letter := String.chr(65 + x)
			draw_string(font, Vector2(float(x) * t_px + t_px * 0.35, _top_px() + 12.0), col_letter, HORIZONTAL_ALIGNMENT_CENTER, -1, 10, Color(1, 0.9, 0.4))

	# Floating Target Loupe upgrade
	if show_loupe and font != null and grid.in_bounds(_hovered_tile.x, _hovered_tile.y):
		var hi := grid.idx_of(_hovered_tile.x, _hovered_tile.y)
		var b_name := str(catalog.capsules.get(catalog.block_int_to_id[grid.base_id[hi]], {}).get("meta", {}).get("name", "Block"))
		var coord_str := "%s%d" % [String.chr(65 + _hovered_tile.x), _hovered_tile.y + 1]
		var loupe_txt := "[%s] %s (T%d) | Z:%d | HP: %.1f/%.1f" % [
			coord_str, b_name, grid.tier[hi], grid.depth[hi],
			maxf(0.0, grid.max_hp[hi] - grid.damage_accum[hi]), grid.max_hp[hi]
		]
		draw_rect(Rect2(6, _top_px() + 4.0, 340, 22), Color(0.05, 0.07, 0.10, 0.88), true)
		draw_string(font, Vector2(12, _top_px() + 19.0), loupe_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.95, 0.98, 1.0))


func _get_tile_color(bid: String, fl_type: int, tier_val: int) -> Color:
	if fl_type == GridManager.FLUID_WATER:
		return Color(0.15, 0.48, 0.92)
	if fl_type == GridManager.FLUID_LAVA:
		return Color(0.95, 0.32, 0.08)
	var base_c := Color(0.42, 0.44, 0.48)
	match bid:
		"blocks/dirt": base_c = Color(0.46, 0.33, 0.21)
		"blocks/stone": base_c = Color(0.42, 0.44, 0.48)
		"blocks/copper": base_c = Color(0.82, 0.46, 0.20)
		"blocks/quartz_vein": base_c = Color(0.82, 0.86, 0.92)
		"blocks/obsidian_hazard": base_c = Color(0.20, 0.07, 0.32)
		_:
			var h := float(abs(bid.hash()) % 360) / 360.0
			var s := 0.38 + float((abs(bid.hash()) >> 8) % 30) / 100.0
			var v := 0.52 + float((abs(bid.hash()) >> 16) % 22) / 100.0
			base_c = Color.from_hsv(h, s, v)
	return base_c.darkened(minf(0.45, float(tier_val) * 0.12))
