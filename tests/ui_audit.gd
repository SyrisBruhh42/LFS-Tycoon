extends SceneTree
## Rendered UI audit. Run WITH a display (not --headless):
##   godot --path . -s tests/ui_audit.gd -- <out_dir>
## Saves a PNG per drawer per resolution and prints a JSON metrics report:
##   - touch-target heights in physical mm (assuming a 489 dpi Pixel 8 Pro), % below the 9 mm guideline
##   - controls overflowing the viewport horizontally
##   - whether a drawer keeps its scroll position after an action-triggered refresh

const SIZES: Array[Vector2i] = [Vector2i(448, 992), Vector2i(1080, 2400)]
const DRAWERS: Array[String] = ["", "bag", "forge", "shop", "homestead"]
const PHONE_DPI: float = 489.0
const MIN_TOUCH_MM: float = 7.4  # Android 48dp at 489 dpi = 7.6 mm (k=3 integer rounding => 7.48)
const MIN_FONT_MM: float = 1.85  # 12 logical px at k=3 on 489 dpi
const DPIS: Array[int] = [96, 489]


func _initialize() -> void:
	var out_dir := "/tmp/ui_audit"
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out_dir = args[0]
	DirAccess.make_dir_recursive_absolute(out_dir)
	var report: Array = []
	var all_ok := true
	for i in SIZES.size():
		var res := await _audit_size(SIZES[i], DPIS[i], out_dir)
		report.append(res)
		if int(res.get("scroll_before", -1)) != 600 or int(res.get("scroll_after_refresh", -2)) != int(res.get("scroll_before", -1)):
			all_ok = false
		var drawers_dict: Dictionary = res.get("drawers", {})
		for d_key in drawers_dict.keys():
			var dm: Dictionary = drawers_dict[d_key]
			if int(dm.get("buttons_under_7_5mm", 0)) != 0:
				all_ok = false
			if int(dm.get("buttons_overflowing_x", 0)) != 0:
				all_ok = false
			if int(dm.get("option_buttons", 0)) != 0:
				all_ok = false
			if not bool(dm.get("font_ok", false)):
				all_ok = false
	print("UI_AUDIT_JSON " + JSON.stringify(report))
	if not all_ok:
		print("UI_AUDIT_FAILED")
		quit(1)
		return
	print("UI_AUDIT_PASS")
	quit(0)


func _audit_size(sz: Vector2i, dpi: int, out_dir: String) -> Dictionary:
	var vp := SubViewport.new()
	vp.size = sz
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var scene: Node = (load("res://scenes/main_quarry.tscn") as PackedScene).instantiate()
	scene.set("forced_dpi", dpi)
	vp.add_child(scene)
	for _i in 4:
		await process_frame
	var mm_per_px: float = 25.4 / float(dpi)
	var ui_k: float = float(scene.get("_ui_k"))
	var result := {"size": "%dx%d@%ddpi" % [sz.x, sz.y, dpi], "ui_k": ui_k, "drawers": {}}
	for d in DRAWERS:
		scene.call("_set_active_drawer", d)
		for _i in 4:
			await process_frame
		var buttons: Array[Button] = []
		_collect_buttons(scene, buttons)
		var vis := 0
		var small := 0
		var min_h := 99999.0
		var overflow := 0
		var opt_count := 0
		for b in buttons:
			if b is OptionButton:
				opt_count += 1
			if not b.is_visible_in_tree():
				continue
			vis += 1
			var r := b.get_global_rect()
			var ph := r.size.y * ui_k
			min_h = minf(min_h, ph)
			if ph * mm_per_px < MIN_TOUCH_MM or r.size.x * ui_k * mm_per_px < MIN_TOUCH_MM:
				small += 1  # too short OR squeezed too narrow to tap (disabled included: squeeze = layout bug)
			if r.end.x * ui_k > float(sz.x) + 1.0 or r.position.x < -1.0:
				overflow += 1
		var min_font := 99999.0
		var labels: Array[Control] = []
		_collect_text(scene, labels)
		for c in labels:
			if c.is_visible_in_tree():
				min_font = minf(min_font, float(c.get_theme_font_size("font_size")) * ui_k)
		var img := vp.get_texture().get_image()
		img.save_png("%s/ui_%dx%d_%s.png" % [out_dir, sz.x, sz.y, d if d != "" else "quarry"])
		result["drawers"][d if d != "" else "quarry"] = {
			"visible_buttons": vis,
			"buttons_under_7_5mm": small,
			"min_button_h_px": min_h if vis > 0 else 0.0,
			"min_button_h_mm": (min_h * mm_per_px) if vis > 0 else 0.0,
			"min_font_mm": min_font * mm_per_px,
			"font_ok": min_font * mm_per_px >= MIN_FONT_MM,
			"buttons_overflowing_x": overflow,
			"option_buttons": opt_count,
		}
	# Scroll-focus retention: scroll the forge drawer, trigger the same refresh a button press performs.
	scene.call("_set_active_drawer", "forge")
	for _i in 4:
		await process_frame
	var sc := _find_scroll(scene)
	if sc != null:
		sc.scroll_vertical = 600
		for _i in 2:
			await process_frame
		var before := sc.scroll_vertical
		scene.call("_refresh_drawer")
		for _i in 4:
			await process_frame
		result["scroll_before"] = before
		result["scroll_after_refresh"] = sc.scroll_vertical
	root.remove_child(vp)
	vp.queue_free()
	return result


func _collect_text(n: Node, out: Array[Control]) -> void:
	if n is Window:
		return  # desktop-only dev calibration window is not player UI
	if n is Label or n is Button:
		out.append(n as Control)
	for c in n.get_children():
		_collect_text(c, out)


func _collect_buttons(n: Node, out: Array[Button]) -> void:
	if n is Window:
		return
	if n is Button:
		out.append(n as Button)
	for c in n.get_children():
		_collect_buttons(c, out)


func _find_scroll(n: Node) -> ScrollContainer:
	if n is ScrollContainer:
		return n as ScrollContainer
	for c in n.get_children():
		var f := _find_scroll(c)
		if f != null:
			return f
	return null
