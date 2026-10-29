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
const STUDIO_BUNDLE_SCHEMA: String = "lfs-image-studio-asset-bundle-v1"
const SPRITESHEET_SCHEMA: String = "lfs-image-studio-spritesheet-v1"
const ROSTER_MASTER_SCHEMA := "lfs-universal-asset-roster-index-v1"
const TIER4_PACKAGE_SCHEMA := "lfs-tier4-game-asset-package-v1"

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


func load_turnaround_bundle(custom_bundle_path: String = "") -> bool:
	return load_studio_bundle(custom_bundle_path)


func get_canvas_texture() -> CanvasTexture:
	if not is_loaded:
		load_studio_bundle()
	return canvas_texture


func get_view_atlas_texture(view_id: String) -> AtlasTexture:
	if not is_loaded:
		load_studio_bundle()
	return view_textures.get(view_id, null) as AtlasTexture


func get_view_texture(view_id: String) -> AtlasTexture:
	return get_view_atlas_texture(view_id)


func get_view_metadata(view_id: String) -> Dictionary:
	if not is_loaded:
		load_studio_bundle()
	return (view_metadata.get(view_id, {}) as Dictionary).duplicate(true)


func resolve_default_enemies_root() -> String:
	var res_root := ProjectSettings.globalize_path("res://")
	var script_dir := ""
	if get_script() != null:
		script_dir = ProjectSettings.globalize_path((get_script() as Script).resource_path).get_base_dir()
	var candidates: Array[String] = [
		res_root.path_join("../willow-desktop-pet/assets/source_art/enemies").simplify_path(),
		res_root.path_join("../../willow-desktop-pet/assets/source_art/enemies").simplify_path(),
		ProjectSettings.globalize_path("res://../willow-desktop-pet/assets/source_art/enemies").simplify_path(),
		ProjectSettings.globalize_path("res://../../willow-desktop-pet/assets/source_art/enemies").simplify_path(),
	]
	if script_dir != "":
		candidates.append(script_dir.path_join("../../willow-desktop-pet/assets/source_art/enemies").simplify_path())
		candidates.append(script_dir.path_join("../../../willow-desktop-pet/assets/source_art/enemies").simplify_path())
	for cand in candidates:
		if FileAccess.file_exists(cand.path_join("ROSTER-MASTER-INDEX.json")) or DirAccess.dir_exists_absolute(cand):
			return cand
	var suite_root := OS.get_environment("LFS_SUITE_ROOT").strip_edges()
	if suite_root != "":
		var env_candidate := suite_root.path_join(
			"3-lfs-aegis-linux/capsules/willow-desktop-pet/assets/source_art/enemies"
		).simplify_path()
		if FileAccess.file_exists(env_candidate.path_join("ROSTER-MASTER-INDEX.json")) or DirAccess.dir_exists_absolute(env_candidate):
			return env_candidate
	return candidates[0]


func load_roster_master_index(enemies_root: String = "") -> Dictionary:
	var root := enemies_root.strip_edges() if enemies_root.strip_edges() != "" else resolve_default_enemies_root()
	var index_path := root.path_join("ROSTER-MASTER-INDEX.json")
	if not FileAccess.file_exists(index_path):
		return {
			"ok": false,
			"error": "roster_master_index_not_found",
			"enemies_root": root,
			"archetype_count": 0,
			"archetypes": []
		}
	var parsed := _load_json_file(index_path)
	var schema_val := str(parsed.get("schema", ""))
	if schema_val != ROSTER_MASTER_SCHEMA:
		return {
			"ok": false,
			"error": "invalid_roster_master_schema",
			"schema": schema_val,
			"enemies_root": root,
			"archetype_count": 0,
			"archetypes": []
		}
	var raw_roster: Variant = parsed.get("roster", parsed.get("archetypes", []))
	var archetypes_arr: Array = raw_roster if typeof(raw_roster) == TYPE_ARRAY else []
	return {
		"ok": true,
		"schema": schema_val,
		"enemies_root": root,
		"archetype_count": archetypes_arr.size(),
		"archetypeCount": int(parsed.get("archetypeCount", archetypes_arr.size())),
		"archetypes": archetypes_arr,
		"roster": archetypes_arr,
		"naming_standard": parsed.get("namingStandard", {})
	}


func list_available_archetypes(enemies_root: String = "") -> Array:
	var index_res := load_roster_master_index(enemies_root)
	if not bool(index_res.get("ok", false)):
		return []
	var result: Array = []
	var archetypes_arr: Array = index_res.get("archetypes", [])
	for entry in archetypes_arr:
		if typeof(entry) == TYPE_DICTIONARY:
			var ed: Dictionary = entry
			var aid := str(ed.get("archetypeId", ed.get("archetype_id", ""))).strip_edges()
			if aid != "" and not result.has(aid):
				result.append(aid)
		elif typeof(entry) == TYPE_STRING:
			var s := str(entry).strip_edges()
			if s != "" and not result.has(s):
				result.append(s)
	return result


func load_archetype_package(archetype_id: String, enemies_root: String = "") -> Dictionary:
	var arch_id := archetype_id.strip_edges()
	var root := enemies_root.strip_edges() if enemies_root.strip_edges() != "" else resolve_default_enemies_root()
	if arch_id == "":
		return {"ok": false, "archetype_id": "", "error": "empty_archetype_id"}
	var arch_dir := root.path_join(arch_id)
	if not DirAccess.dir_exists_absolute(arch_dir):
		return {"ok": false, "archetype_id": arch_id, "error": "archetype_dir_not_found"}

	var manifest_doc := _load_json_file(arch_dir.path_join("manifest.json"))
	var lore_doc := _load_json_file(arch_dir.path_join("lore_profile.json"))
	var rig_doc := _load_json_file(arch_dir.path_join("rig_bones.json"))
	var studio_dir := arch_dir.path_join("studio_maps")
	var pbr_doc := _load_json_file(studio_dir.path_join("pbr_bundle.json"))
	var tier4_doc := _load_json_file(arch_dir.path_join("capsule_asset_package.json"))
	var game_ready_dir := arch_dir.path_join("game_ready")
	var spritesheet_json_path := game_ready_dir.path_join("%s_spritesheet.json" % arch_id)
	var spritesheet_doc := _load_json_file(spritesheet_json_path)

	if manifest_doc.is_empty() and lore_doc.is_empty() and pbr_doc.is_empty():
		return {"ok": false, "archetype_id": arch_id, "error": "missing_archetype_metadata"}

	var passes_dict: Dictionary = pbr_doc.get("passes", {}) if typeof(pbr_doc.get("passes", {})) == TYPE_DICTIONARY else {}
	var albedo_file := _resolve_pass_filename(passes_dict, "albedo", "%s_albedo.png" % arch_id)
	var normal_file := _resolve_pass_filename(passes_dict, "normal", "%s_normal.png" % arch_id)
	var orm_file := _resolve_pass_filename(passes_dict, "orm", "%s_orm.png" % arch_id)
	var depth_file := _resolve_pass_filename(passes_dict, "depth", "%s_depth.png" % arch_id)
	var emissive_file := _resolve_pass_filename(passes_dict, "emissive", "%s_emissive.png" % arch_id)

	var tex_albedo := _load_image_texture(studio_dir.path_join(albedo_file))
	var tex_normal := _load_image_texture(studio_dir.path_join(normal_file))
	var tex_orm := _load_image_texture(studio_dir.path_join(orm_file))
	var tex_depth := _load_image_texture(studio_dir.path_join(depth_file))
	var tex_emissive := _load_image_texture(studio_dir.path_join(emissive_file))

	if tex_albedo == null:
		return {"ok": false, "archetype_id": arch_id, "error": "albedo_texture_load_failed"}

	var arch_canvas_tex := CanvasTexture.new()
	arch_canvas_tex.diffuse_texture = tex_albedo
	if tex_normal != null:
		arch_canvas_tex.normal_texture = tex_normal
	if tex_orm != null:
		arch_canvas_tex.specular_texture = tex_orm

	var pbr_textures := {
		"albedo": tex_albedo,
		"normal": tex_normal,
		"orm": tex_orm,
		"depth": tex_depth,
		"emissive": tex_emissive
	}

	var default_socket_anchors := _extract_rig_socket_anchors(rig_doc)
	var spritesheet_frames: Array = []
	var sheet_canvas_tex: CanvasTexture = arch_canvas_tex

	if not spritesheet_doc.is_empty():
		var sheet_albedo := _load_image_texture(game_ready_dir.path_join("%s_spritesheet_albedo.png" % arch_id))
		var sheet_normal := _load_image_texture(game_ready_dir.path_join("%s_spritesheet_normal.png" % arch_id))
		var sheet_orm := _load_image_texture(game_ready_dir.path_join("%s_spritesheet_orm.png" % arch_id))
		if sheet_albedo != null:
			sheet_canvas_tex = CanvasTexture.new()
			sheet_canvas_tex.diffuse_texture = sheet_albedo
			if sheet_normal != null:
				sheet_canvas_tex.normal_texture = sheet_normal
			if sheet_orm != null:
				sheet_canvas_tex.specular_texture = sheet_orm

		var frames_map: Dictionary = spritesheet_doc.get("frames", {}) if typeof(spritesheet_doc.get("frames", {})) == TYPE_DICTIONARY else {}
		var frame_keys: Array = frames_map.keys()
		frame_keys.sort()
		for f_key in frame_keys:
			var f_val: Variant = frames_map[f_key]
			if typeof(f_val) != TYPE_DICTIONARY:
				continue
			var fd: Dictionary = f_val
			var r_dict: Dictionary = fd.get("frame", {}) if typeof(fd.get("frame", {})) == TYPE_DICTIONARY else {}
			var region := Rect2(
				float(r_dict.get("x", 0)),
				float(r_dict.get("y", 0)),
				float(r_dict.get("w", 180)),
				float(r_dict.get("h", 320))
			)
			var frame_atlas := AtlasTexture.new()
			frame_atlas.atlas = sheet_canvas_tex
			frame_atlas.region = region
			frame_atlas.filter_clip = true

			var pv_dict: Dictionary = fd.get("pivot", {}) if typeof(fd.get("pivot", {})) == TYPE_DICTIONARY else {}
			var frame_pivot := Vector2(float(pv_dict.get("x", CANONICAL_PIVOT.x)), float(pv_dict.get("y", CANONICAL_PIVOT.y)))

			var raw_cboxes: Dictionary = fd.get("combatBoxes", fd.get("combat_boxes", {})) if typeof(fd.get("combatBoxes", fd.get("combat_boxes", {}))) == TYPE_DICTIONARY else {}
			var hurtbox: Dictionary = raw_cboxes.get("hurtbox", {
				"x": int(region.size.x * 0.2),
				"y": int(region.size.y * 0.15),
				"w": int(region.size.x * 0.6),
				"h": int(region.size.y * 0.75)
			})
			var melee_hitbox: Dictionary = raw_cboxes.get("meleeHitbox", {
				"x": int(region.size.x * 0.1),
				"y": int(region.size.y * 0.25),
				"w": int(region.size.x * 0.8),
				"h": int(region.size.y * 0.5)
			})
			var combat_boxes := {
				"hurtbox": hurtbox,
				"meleeHitbox": melee_hitbox
			}
			var socket_anchors: Dictionary = fd.get("socketAnchors", fd.get("socket_anchors", default_socket_anchors)) if typeof(fd.get("socketAnchors", fd.get("socket_anchors", default_socket_anchors))) == TYPE_DICTIONARY else default_socket_anchors

			spritesheet_frames.append({
				"frame_id": str(f_key),
				"atlas_texture": frame_atlas,
				"texture": frame_atlas,
				"region": region,
				"pivot": frame_pivot,
				"combatBoxes": combat_boxes,
				"hurtbox": hurtbox,
				"meleeHitbox": melee_hitbox,
				"socketAnchors": socket_anchors
			})

	var combat_stats: Dictionary = {}
	if typeof(lore_doc.get("combatMechanics", null)) == TYPE_DICTIONARY:
		combat_stats.merge(lore_doc.get("combatMechanics", {}), true)
	if typeof(tier4_doc.get("combatStats", null)) == TYPE_DICTIONARY:
		combat_stats.merge(tier4_doc.get("combatStats", {}), true)
	if combat_stats.is_empty():
		combat_stats = {"tier": str(lore_doc.get("category", "standard")), "abilities": []}

	var display_name := str(
		lore_doc.get("displayName", manifest_doc.get("displayName", rig_doc.get("displayName", arch_id)))
	)
	var tier4_schema := str(tier4_doc.get("schema", TIER4_PACKAGE_SCHEMA))

	return {
		"ok": true,
		"archetype_id": arch_id,
		"display_name": display_name,
		"lore_profile": lore_doc,
		"rig_bones": rig_doc,
		"manifest": manifest_doc,
		"pbr_bundle": pbr_doc,
		"capsule_asset_package": tier4_doc,
		"tier4_schema": tier4_schema,
		"combat_stats": combat_stats,
		"canvas_texture": arch_canvas_tex,
		"depth_texture": tex_depth,
		"emissive_texture": tex_emissive,
		"pbr_textures": pbr_textures,
		"spritesheet_frames": spritesheet_frames,
		"foot_pivot": CANONICAL_PIVOT
	}


static func _resolve_pass_filename(passes_dict: Dictionary, pass_key: String, default_filename: String) -> String:
	if passes_dict.has(pass_key):
		var entry: Variant = passes_dict[pass_key]
		if typeof(entry) == TYPE_DICTIONARY and (entry as Dictionary).has("file"):
			return str((entry as Dictionary)["file"])
		elif typeof(entry) == TYPE_STRING and str(entry).strip_edges() != "":
			return str(entry).strip_edges()
	return default_filename


static func _extract_rig_socket_anchors(rig_doc: Dictionary) -> Dictionary:
	var anchors: Dictionary = {}
	var bones_arr: Variant = rig_doc.get("bones", [])
	if typeof(bones_arr) == TYPE_ARRAY:
		for b_entry in bones_arr:
			if typeof(b_entry) == TYPE_DICTIONARY:
				var bd: Dictionary = b_entry
				var sock: Variant = bd.get("equipmentSocket", null)
				if sock != null and str(sock).strip_edges() != "":
					anchors[str(sock).strip_edges()] = {
						"bone": str(bd.get("name", "")),
						"xRatio": float(bd.get("xRatio", 0.5)),
						"yRatio": float(bd.get("yRatio", 0.5)),
						"xPx": int(bd.get("xPx", 0)),
						"yPx": int(bd.get("yPx", 0))
					}
	return anchors


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

