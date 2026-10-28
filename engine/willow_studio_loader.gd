class_name WillowStudioLoader
extends RefCounted
## Godot 4.3 Runtime Willow Studio PBR Turnaround Loader (CRUCIBLE-07 & SR-02).
## Loads Willow's 5-view 3600x1280 PBR turnaround atlas (albedo, normal, ORM) at runtime via
## Image.load_from_file() -> ImageTexture.create_from_image() -> CanvasTexture + AtlasTexture,
## avoiding cross-capsule res:// collisions and enforcing CM-02 anatomical laterality
## (flip_h = false on 05_side_left_270deg so WristPropSocket.R is never mirrored).

const VIEW_ORDER: Array[String] = [
	"01_front_0deg",
	"02_side_right_90deg",
	"03_three_quarter_45deg",
	"04_back_180deg",
	"05_side_left_270deg"
]

const PANEL_WIDTH: int = 720
const PANEL_HEIGHT: int = 1280
const CANONICAL_PIVOT: Vector2 = Vector2(0.5, 0.9)

var bundle_path: String = ""
var studio_maps_dir: String = ""
var bundle_manifest: Dictionary = {}
var atlas_descriptor: Dictionary = {}
var albedo_texture: ImageTexture = null
var normal_texture: ImageTexture = null
var orm_texture: ImageTexture = null
var canvas_texture: CanvasTexture = null
var view_textures: Dictionary = {}
var view_metadata: Dictionary = {}
var is_loaded: bool = false


static func resolve_default_bundle_path() -> String:
	var rel_candidate := ProjectSettings.globalize_path("res://").path_join(
		"../willow-desktop-pet/assets/source_art/turnaround/studio_maps/studio_asset_bundle.json"
	).simplify_path()
	if FileAccess.file_exists(rel_candidate):
		return rel_candidate
	var res_candidate := ProjectSettings.globalize_path(
		"res://../willow-desktop-pet/assets/source_art/turnaround/studio_maps/studio_asset_bundle.json"
	).simplify_path()
	if FileAccess.file_exists(res_candidate):
		return res_candidate
	var suite_root := OS.get_environment("LFS_SUITE_ROOT").strip_edges()
	if suite_root != "":
		var env_candidate := suite_root.path_join(
			"3-lfs-aegis-linux/capsules/willow-desktop-pet/assets/source_art/turnaround/studio_maps/studio_asset_bundle.json"
		).simplify_path()
		if FileAccess.file_exists(env_candidate):
			return env_candidate
	return rel_candidate


func load_studio_bundle(custom_bundle_path: String = "") -> bool:
	bundle_path = custom_bundle_path.strip_edges() if custom_bundle_path.strip_edges() != "" else resolve_default_bundle_path()
	if not FileAccess.file_exists(bundle_path):
		is_loaded = false
		return false

	studio_maps_dir = bundle_path.get_base_dir()
	bundle_manifest = _load_json_file(bundle_path)
	if bundle_manifest.is_empty():
		is_loaded = false
		return false

	var desc_path := studio_maps_dir.path_join("turnaround_atlas.json")
	if FileAccess.file_exists(desc_path):
		atlas_descriptor = _load_json_file(desc_path)

	var albedo_path := studio_maps_dir.path_join("turnaround_atlas_albedo.png")
	var normal_path := studio_maps_dir.path_join("turnaround_atlas_normal.png")
	var orm_path := studio_maps_dir.path_join("turnaround_atlas_orm.png")

	albedo_texture = _load_image_texture(albedo_path)
	normal_texture = _load_image_texture(normal_path)
	orm_texture = _load_image_texture(orm_path)
	if albedo_texture == null:
		is_loaded = false
		return false

	canvas_texture = CanvasTexture.new()
	canvas_texture.diffuse_texture = albedo_texture
	if normal_texture != null:
		canvas_texture.normal_texture = normal_texture
	if orm_texture != null:
		canvas_texture.specular_texture = orm_texture

	view_textures.clear()
	view_metadata.clear()
	var views_arr: Array = bundle_manifest.get("views", []) if typeof(bundle_manifest.get("views", [])) == TYPE_ARRAY else []
	var frames_dict: Dictionary = atlas_descriptor.get("frames", {}) if typeof(atlas_descriptor.get("frames", {})) == TYPE_DICTIONARY else {}

	for idx in VIEW_ORDER.size():
		var vid := VIEW_ORDER[idx]
		var region := Rect2(float(idx * PANEL_WIDTH), 0.0, float(PANEL_WIDTH), float(PANEL_HEIGHT))
		var pivot := CANONICAL_PIVOT
		var sockets: Array = []
		var angle_deg: int = idx * 45
		var viewer_facing: String = ""
		var anatomical_side: String = ""

		if frames_dict.has(vid) and typeof(frames_dict[vid]) == TYPE_DICTIONARY:
			var f_info: Dictionary = frames_dict[vid]
			if f_info.has("fullPanelFrame") and typeof(f_info["fullPanelFrame"]) == TYPE_DICTIONARY:
				var fp: Dictionary = f_info["fullPanelFrame"]
				region = Rect2(
					float(fp.get("x", idx * PANEL_WIDTH)),
					float(fp.get("y", 0)),
					float(fp.get("w", PANEL_WIDTH)),
					float(fp.get("h", PANEL_HEIGHT))
				)
			if f_info.has("pivot") and typeof(f_info["pivot"]) == TYPE_DICTIONARY:
				var pv: Dictionary = f_info["pivot"]
				pivot = Vector2(float(pv.get("x", 0.5)), float(pv.get("y", 0.9)))

		for v_entry in views_arr:
			if typeof(v_entry) == TYPE_DICTIONARY and str((v_entry as Dictionary).get("viewId", "")) == vid:
				var vd: Dictionary = v_entry
				sockets = vd.get("visibleWardrobeSockets", [])
				angle_deg = int(vd.get("angleDeg", angle_deg))
				viewer_facing = str(vd.get("viewerFacing", ""))
				anatomical_side = str(vd.get("anatomicalSide", ""))
				break

		var atlas_tex := AtlasTexture.new()
		atlas_tex.atlas = canvas_texture
		atlas_tex.region = region
		atlas_tex.filter_clip = true
		view_textures[vid] = atlas_tex

		# CM-02 Laterality Invariant: 05_side_left_270deg is a dedicated baked view and MUST NEVER be horizontally flipped.
		view_metadata[vid] = {
			"viewId": vid,
			"region": region,
			"pivot": pivot,
			"flip_h": false,
			"angleDeg": angle_deg,
			"viewerFacing": viewer_facing,
			"anatomicalSide": anatomical_side,
			"visibleWardrobeSockets": sockets
		}

	is_loaded = true
	return true


func get_canvas_texture() -> CanvasTexture:
	if not is_loaded:
		load_studio_bundle()
	return canvas_texture


func get_view_atlas_texture(view_id: String) -> AtlasTexture:
	if not is_loaded:
		load_studio_bundle()
	return view_textures.get(view_id, null) as AtlasTexture


func get_view_metadata(view_id: String) -> Dictionary:
	if not is_loaded:
		load_studio_bundle()
	return (view_metadata.get(view_id, {}) as Dictionary).duplicate(true)


static func _load_image_texture(abs_path: String) -> ImageTexture:
	if not FileAccess.file_exists(abs_path):
		return null
	var img := Image.load_from_file(abs_path)
	if img == null or img.is_empty():
		return null
	return ImageTexture.create_from_image(img)


static func _load_json_file(abs_path: String) -> Dictionary:
	if not FileAccess.file_exists(abs_path):
		return {}
	var raw := FileAccess.get_file_as_string(abs_path)
	if raw.strip_edges() == "":
		return {}
	var parsed: Variant = JSON.parse_string(raw)
	if typeof(parsed) == TYPE_DICTIONARY:
		return parsed as Dictionary
	return {}
