class_name Generator3D
extends RefCounted
## 3D Procedural Vein & Biome Generator with Baked Empirical Quantile LUT & Conditional Priority Scaling.

const FALLBACK_BLOCK: String = "blocks/stone"

var catalog: CatalogDB
var master_seed: int = 1337
var quantile_lut: PackedFloat32Array = PackedFloat32Array()
var _noises: Dictionary = {}               # block_id -> FastNoiseLite
var _biome_noise: FastNoiseLite
var slider_overrides: Dictionary = {}      # block_id -> float (live override from Linux Dev Window)
var locked_sliders: Dictionary = {}        # block_id -> bool


func _init(p_catalog: CatalogDB, p_seed: int = 1337) -> void:
	catalog = p_catalog
	master_seed = p_seed
	_init_noises()
	_build_or_load_quantile_lut()


func _init_noises() -> void:
	_noises.clear()
	_biome_noise = FastNoiseLite.new()
	_biome_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_biome_noise.fractal_type = FastNoiseLite.FRACTAL_NONE
	_biome_noise.frequency = 1.0 / 32.0
	_biome_noise.seed = master_seed ^ 0x5A5A5A

	for bid in catalog.block_ids_sorted:
		var nz := FastNoiseLite.new()
		nz.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		nz.fractal_type = FastNoiseLite.FRACTAL_NONE
		nz.frequency = 1.0
		# Seed derives from the block ID (not its sort index) so adding new capsules
		# never reshuffles the terrain of existing blocks.
		nz.seed = int((master_seed + int(String(bid).hash())) & 0x7FFFFFFF)
		_noises[bid] = nz


func _build_or_load_quantile_lut() -> void:
	var bins := catalog.get_gmst_int("fQuantileLutBins", 2048)
	var sample_count := catalog.get_gmst_int("fQuantileSampleCount", 262144)
	var cache_path := "user://quantile_lut_%d_%d.bin" % [bins, sample_count]

	if FileAccess.file_exists(cache_path):
		var f := FileAccess.open(cache_path, FileAccess.READ)
		if f != null and f.get_length() == bins * 4:
			quantile_lut = f.get_buffer(bins * 4).to_float32_array()
			if quantile_lut.size() == bins:
				return

	var ref_noise := FastNoiseLite.new()
	ref_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	ref_noise.fractal_type = FastNoiseLite.FRACTAL_NONE
	ref_noise.frequency = 1.0
	ref_noise.seed = 1337

	var rng := RandomNumberGenerator.new()
	rng.seed = 9001
	var samples := PackedFloat32Array()
	samples.resize(sample_count)
	for i in sample_count:
		samples[i] = ref_noise.get_noise_3d(
			rng.randf() * 16384.0,
			rng.randf() * 16384.0,
			rng.randf() * 16384.0
		)
	samples.sort()

	quantile_lut.resize(bins)
	for b in bins:
		var frac := float(b) / float(bins - 1)
		var s_idx := int(round(frac * float(sample_count - 1)))
		quantile_lut[b] = samples[clampi(s_idx, 0, sample_count - 1)]

	var fw := FileAccess.open(cache_path, FileAccess.WRITE)
	if fw != null:
		fw.store_buffer(quantile_lut.to_byte_array())


## Maps raw FastNoiseLite sample n in [-1, 1] to uniform u in [0, 1] via Empirical Quantile LUT.
func raw_to_uniform(n: float) -> float:
	var sz := quantile_lut.size()
	if sz <= 1:
		return clampf((n + 1.0) * 0.5, 0.0, 1.0)
	if n <= quantile_lut[0]:
		return 0.0
	if n >= quantile_lut[sz - 1]:
		return 1.0
	var idx := quantile_lut.bsearch(n)
	if idx <= 0:
		return 0.0
	var lo := quantile_lut[idx - 1]
	var hi := quantile_lut[idx]
	var t := (n - lo) / maxf(0.000001, hi - lo)
	return clampf((float(idx - 1) + t) / float(sz - 1), 0.0, 1.0)


## Computes active biome ID at coordinate (x, y, z)
func get_biome_at(x: int, y: int, z: int) -> String:
	# Active non-default biomes at depth z occupy DISJOINT noise bands (sorted by ID, so
	# deterministic and independent of load order). Total coverage is capped at 90% so
	# many biome capsules can coexist without shadowing each other.
	var active: Array[Dictionary] = []
	var total_w := 0.0
	for b_id in catalog.biome_ids:
		if b_id == "biomes/standard_crust":
			continue
		var b_cap: Dictionary = catalog.capsules.get(b_id, {})
		var st: Dictionary = b_cap.get("stats", {})
		var z_min := int(st.get("z_min", 0))
		var z_max := int(st.get("z_max", 999999))
		if z >= z_min and z <= z_max:
			var w := maxf(0.0, float(st.get("weight", 0.25)))
			if w > 0.0:
				active.append({"id": b_id, "w": w})
				total_w += w
	if active.is_empty():
		return "biomes/standard_crust"
	var scale := minf(1.0, 0.9 / total_w)
	var u := raw_to_uniform(_biome_noise.get_noise_3d(float(x), float(y), float(z)))
	var acc := 0.0
	for a in active:
		acc += float(a["w"]) * scale
		if u >= 1.0 - acc:
			return String(a["id"])
	return "biomes/standard_crust"


## Resolves the 2-tuple tier for a block at depth z: floor((z - z_unlock) / l_step)
func get_tier_for_block(block_id: String, z: int) -> int:
	var cap: Dictionary = catalog.capsules.get(block_id, {})
	var st: Dictionary = cap.get("stats", {})
	var z_unlock := int(st.get("z_unlock", 0))
	var l_step := maxi(1, int(st.get("l_step", 1000)))
	if z < z_unlock:
		return 0
	return int(floor(float(z - z_unlock) / float(l_step)))


## Returns full voxel specification at (x, y, z) including underlying solid substrate and optional fluid overlay.
func sample_voxel(x: int, y: int, z: int, local_imbalance: float = 0.0, use_biome_weights: bool = true) -> Dictionary:
	var biome_id := get_biome_at(x, y, z) if use_biome_weights else "biomes/standard_crust"
	var biome_cap: Dictionary = catalog.capsules.get(biome_id, {})
	var b_weights: Dictionary = biome_cap.get("biome_weights", {})

	var remaining_mass := 1.0
	var chosen_fluid_block := ""
	var chosen_solid_block := ""
	# The world-fill block is a FIXED constant — never "whichever block sorts last" —
	# so newly added block capsules can never hijack the world fill.
	var fallback_block := FALLBACK_BLOCK

	for i in catalog.block_ids_sorted.size():
		var bid: String = catalog.block_ids_sorted[i]
		if bid == fallback_block:
			continue
		var cap: Dictionary = catalog.capsules[bid]
		var st: Dictionary = cap.get("stats", {})
		var z_unlock := int(st.get("z_unlock", 0))
		var z_max := int(st.get("z_max", 2147483647))
		if z < z_unlock or z > z_max:
			continue

		var fluid_type := str(st.get("fluid_type", "NONE"))
		var is_fluid := fluid_type != "NONE"
		# Once a solid is chosen, keep scanning ONLY for fluid overlays (independent layer).
		if chosen_solid_block != "" and not is_fluid:
			continue
		if is_fluid and chosen_fluid_block != "":
			continue

		var base_p := float(slider_overrides.get(bid, st.get("spawn_prob", 0.05)))
		if use_biome_weights and b_weights.has(bid):
			base_p *= float(b_weights[bid])

		# Apply local directional topographical imbalance boost to hazards
		if int(st.get("is_hazard", 0)) == 1 and local_imbalance > 0.0:
			var pen_max := catalog.get_gmst_float("fImbalancePenaltyMax", 0.15)
			var div := maxf(1.0, catalog.get_gmst_float("fImbalanceScaleDivisor", 35.0))
			base_p += pen_max * (1.0 - exp(-local_imbalance / div))

		base_p = clampf(base_p, 0.0, 0.98)
		if base_p <= 0.0:
			continue

		# Conditional probability correction so priority order does not shadow later resources
		var p_cond := clampf(base_p / maxf(0.0001, remaining_mass if not is_fluid else 1.0), 0.0, 1.0)
		var clump_xy := maxf(0.01, float(st.get("clump_xy", 8.0)))
		var pipe_z := maxf(0.01, float(st.get("pipe_z", 8.0)))
		var nz: FastNoiseLite = _noises[bid]
		var raw_n := nz.get_noise_3d(float(x) / clump_xy, float(y) / clump_xy, float(z) / pipe_z)
		var u := raw_to_uniform(raw_n)

		if is_fluid:
			# Fluids are an independent overlay; a solid substrate is still resolved underneath.
			if u >= 1.0 - p_cond:
				chosen_fluid_block = bid
		else:
			remaining_mass = maxf(0.0, remaining_mass - base_p)
			if u >= 1.0 - p_cond:
				chosen_solid_block = bid

	if chosen_solid_block == "":
		chosen_solid_block = fallback_block

	var solid_tier := get_tier_for_block(chosen_solid_block, z)
	var solid_st: Dictionary = catalog.capsules.get(chosen_solid_block, {}).get("stats", {})
	var solid_hp := float(solid_st.get("base_hp", 10.0)) * pow(1.8, float(solid_tier))

	var fluid_type_out := "NONE"
	var fluid_buckets := 0
	if chosen_fluid_block != "":
		var fl_st: Dictionary = catalog.capsules.get(chosen_fluid_block, {}).get("stats", {})
		fluid_type_out = str(fl_st.get("fluid_type", "WATER"))
		fluid_buckets = int(fl_st.get("initial_fluid_buckets", 3))

	return {
		"solid_id": chosen_solid_block,
		"solid_int": int(catalog.block_id_to_int.get(chosen_solid_block, 0)),
		"tier": solid_tier,
		"max_hp": solid_hp,
		"fluid_block_id": chosen_fluid_block,
		"fluid_type": fluid_type_out,
		"fluid_level": fluid_buckets,
		"biome_id": biome_id
	}


## Computes empirical per-sheet statistics (mean %, P(zero), p10, p90) across sample_sheets sheets of size cols x rows.
func compute_sheet_diagnostics(block_id: String, z: int, cols: int = 14, rows: int = 31, sample_sheets: int = 200) -> Dictionary:
	var counts: Array[float] = []
	var zero_sheets := 0
	var total_tiles := float(cols * rows)
	for s in sample_sheets:
		var x0 := s * 37
		var y0 := s * 53
		var hits := 0
		for yy in rows:
			for xx in cols:
				var v := sample_voxel(x0 + xx, y0 + yy, z, 0.0, false)
				if v["solid_id"] == block_id or v["fluid_block_id"] == block_id:
					hits += 1
		if hits == 0:
			zero_sheets += 1
		counts.append(float(hits) / total_tiles)
	counts.sort()
	var mean := 0.0
	for c in counts:
		mean += c
	mean /= maxf(1.0, float(counts.size()))
	return {
		"mean_pct": mean * 100.0,
		"p_zero_pct": (float(zero_sheets) / maxf(1.0, float(sample_sheets))) * 100.0,
		"p10_pct": counts[int(0.10 * (counts.size() - 1))] * 100.0,
		"p90_pct": counts[int(0.90 * (counts.size() - 1))] * 100.0
	}
