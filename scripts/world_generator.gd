# Deterministic chunk generator that uses the world-generation data contracts.
extends Node2D
class_name WorldGenerator

@export var auto_generate_on_ready: bool = true
@export var debug_draw_tile_size: float = 4.0
@export var center_world_on_node: bool = true
@export var generate_around_origin: bool = true
@export_file("*.tres") var world_type_settings_path: String = "res://scripts/world_type1.tres"
@export var world_type_settings: WorldGenerationClasses
@export_dir var feature_meshes_root_dir: String = "res://assets/features"
@export var scan_feature_folders_on_ready: bool = true

var settings: WorldGenerationClasses.WorldGenerationSettings
var faction_rules_by_id: Dictionary = {}

var _height_noise: FastNoiseLite = FastNoiseLite.new()
var _moisture_noise: FastNoiseLite = FastNoiseLite.new()
var _temperature_noise: FastNoiseLite = FastNoiseLite.new()
var _debug_chunks: Dictionary = {}
var _feature_variants_by_id: Dictionary = {}


func _ready() -> void:
	if scan_feature_folders_on_ready:
		_scan_feature_folders()
	if auto_generate_on_ready:
		if settings == null:
			setup(_load_or_create_world_settings())
		_generate_debug_world()
		queue_redraw()


func _draw() -> void:
	if settings == null or _debug_chunks.is_empty():
		return

	var min_chunk: Vector2i = _find_min_chunk_coord()
	var chunk_world_pixels: float = settings.chunk_size_tiles * debug_draw_tile_size
	var total_world_size: Vector2 = Vector2(
		settings.world_width_chunks * chunk_world_pixels,
		settings.world_height_chunks * chunk_world_pixels
	)
	var draw_origin: Vector2 = Vector2.ZERO
	if center_world_on_node:
		draw_origin = -total_world_size * 0.5

	for chunk_coord_variant in _debug_chunks.keys():
		var chunk_coord: Vector2i = chunk_coord_variant
		var chunk: WorldGenerationClasses.ChunkWorldLayerData = _debug_chunks[chunk_coord]
		var local_chunk_coord: Vector2i = chunk_coord - min_chunk
		var chunk_offset: Vector2 = draw_origin + Vector2(
			local_chunk_coord.x * chunk_world_pixels,
			local_chunk_coord.y * chunk_world_pixels
		)
		for local_y: int in settings.chunk_size_tiles:
			for local_x: int in settings.chunk_size_tiles:
				var index: int = local_y * settings.chunk_size_tiles + local_x
				var surface: int = int(chunk.surface_ids[index])
				draw_rect(
					Rect2(
						chunk_offset.x + local_x * debug_draw_tile_size,
						chunk_offset.y + local_y * debug_draw_tile_size,
						debug_draw_tile_size,
						debug_draw_tile_size
					),
					_color_for_surface(surface),
					true
				)


func setup(new_settings: WorldGenerationClasses.WorldGenerationSettings, faction_rules: Array[WorldGenerationClasses.FactionConstructionRules] = []) -> void:
	settings = new_settings
	faction_rules_by_id.clear()
	for rules: WorldGenerationClasses.FactionConstructionRules in faction_rules:
		faction_rules_by_id[rules.faction_id] = rules
	_apply_noise_settings(_height_noise, settings.world_type.continent_scale, settings.seed)
	_apply_noise_settings(_moisture_noise, settings.world_type.continent_scale * 1.8, settings.seed + 404)
	_apply_noise_settings(_temperature_noise, settings.world_type.continent_scale * 1.2, settings.seed + 909)


func regenerate_debug_world() -> void:
	if settings == null:
		setup(_load_or_create_world_settings())
	_generate_debug_world()
	queue_redraw()


func get_feature_variants() -> Dictionary:
	return _feature_variants_by_id.duplicate(true)


func _scan_feature_folders() -> void:
	_feature_variants_by_id.clear()
	if feature_meshes_root_dir.is_empty():
		push_warning("WorldGenerator: feature mesh root folder not set.")
		return

	var root: DirAccess = DirAccess.open(feature_meshes_root_dir)
	if root == null:
		push_warning("WorldGenerator: failed to open feature mesh root folder: %s" % feature_meshes_root_dir)
		return

	root.list_dir_begin()
	while true:
		var entry: String = root.get_next()
		if entry.is_empty():
			break
		if entry.begins_with("."):
			continue
		if not root.current_is_dir():
			continue
		if entry.ends_with("_bb"):
			continue

		var feature_id: StringName = StringName(entry)
		var mesh_dir: String = "%s/%s" % [feature_meshes_root_dir, entry]
		var billboard_dir: String = "%s/%s_bb" % [feature_meshes_root_dir, entry]

		var mesh_files: PackedStringArray = _list_scene_like_files(mesh_dir)
		var billboard_files: PackedStringArray = _list_scene_like_files(billboard_dir)

		_feature_variants_by_id[feature_id] = {
			"mesh": mesh_files,
			"billboard": billboard_files,
		}
	root.list_dir_end()


func _list_scene_like_files(dir_path: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return out

	dir.list_dir_begin()
	while true:
		var entry: String = dir.get_next()
		if entry.is_empty():
			break
		if entry.begins_with("."):
			continue
		if dir.current_is_dir():
			continue
		var lowered: String = entry.to_lower()
		if lowered.ends_with(".tscn") or lowered.ends_with(".scn") or lowered.ends_with(".glb") or lowered.ends_with(".gltf") or lowered.ends_with(".mesh"):
			out.append("%s/%s" % [dir_path, entry])
	dir.list_dir_end()
	return out


func pick_feature_asset(feature_id: StringName, use_billboard: bool = false) -> String:
	if not _feature_variants_by_id.has(feature_id):
		return ""
	var variants: Dictionary = _feature_variants_by_id[feature_id]
	var key: String = "billboard" if use_billboard else "mesh"
	var paths: PackedStringArray = variants.get(key, PackedStringArray())
	if paths.is_empty() and use_billboard:
		paths = variants.get("mesh", PackedStringArray())
	if paths.is_empty():
		return ""
	return paths[0]


func _generate_debug_world() -> void:
	_debug_chunks.clear()
	var start_x: int = 0
	var start_y: int = 0
	if generate_around_origin:
		start_x = -int(floor(settings.world_width_chunks * 0.5))
		start_y = -int(floor(settings.world_height_chunks * 0.5))
	for chunk_y: int in settings.world_height_chunks:
		for chunk_x: int in settings.world_width_chunks:
			var chunk_coord: Vector2i = Vector2i(start_x + chunk_x, start_y + chunk_y)
			_debug_chunks[chunk_coord] = generate_chunk(chunk_coord)


func _find_min_chunk_coord() -> Vector2i:
	var first: bool = true
	var min_coord: Vector2i = Vector2i.ZERO
	for chunk_coord_variant in _debug_chunks.keys():
		var chunk_coord: Vector2i = chunk_coord_variant
		if first:
			min_coord = chunk_coord
			first = false
		else:
			min_coord.x = mini(min_coord.x, chunk_coord.x)
			min_coord.y = mini(min_coord.y, chunk_coord.y)
	return min_coord


func generate_chunk(chunk_coord: Vector2i) -> WorldGenerationClasses.ChunkWorldLayerData:
	assert(settings != null, "WorldGenerator.setup must be called before generate_chunk.")
	var chunk: WorldGenerationClasses.ChunkWorldLayerData = WorldGenerationClasses.ChunkWorldLayerData.new()
	chunk.chunk_coord = chunk_coord
	var tile_count: int = settings.chunk_size_tiles * settings.chunk_size_tiles
	chunk.surface_ids.resize(tile_count)
	chunk.biome_ids.resize(tile_count)
	chunk.height_values.resize(tile_count)

	for local_y: int in settings.chunk_size_tiles:
		for local_x: int in settings.chunk_size_tiles:
			var world_tile: Vector2i = Vector2i(
				chunk_coord.x * settings.chunk_size_tiles + local_x,
				chunk_coord.y * settings.chunk_size_tiles + local_y
			)
			var index: int = local_y * settings.chunk_size_tiles + local_x
			var normalized_height: float = _sample_height(world_tile)
			var moisture: float = _sample_moisture(world_tile)
			var temperature: float = _sample_temperature(world_tile)
			var biome: WorldGenerationClasses.TerrainBiome = _pick_biome(normalized_height, moisture, temperature)
			chunk.height_values[index] = normalized_height
			chunk.biome_ids[index] = clampi(biome.biome_id, 0, 255)
			chunk.surface_ids[index] = clampi(_resolve_surface_id(biome, normalized_height), 0, 255)

	_generate_natural_features(chunk)
	_generate_road_overlay(chunk)
	return chunk


func try_place_construction(chunk: WorldGenerationClasses.ChunkWorldLayerData, owner_faction_id: int, definition: WorldGenerationClasses.InteractableDefinition, world_position: Vector3, is_road: bool, is_building: bool) -> bool:
	if not faction_rules_by_id.has(owner_faction_id):
		return false
	var rules: WorldGenerationClasses.FactionConstructionRules = faction_rules_by_id[owner_faction_id]
	if rules.build_permissions == null:
		return false
	if is_road and not rules.build_permissions.can_place_roads:
		return false
	if is_building and not rules.build_permissions.can_place_buildings:
		return false
	if not rules.build_permissions.can_place_definition(definition.definition_id):
		return false

	var record: WorldGenerationClasses.ConstructionRecord = WorldGenerationClasses.ConstructionRecord.new()
	record.construction_id = _stable_hash([settings.seed, owner_faction_id, int(world_position.x), int(world_position.z), chunk.construction_feature_records.size()])
	record.definition_id = definition.definition_id
	record.owner_faction_id = owner_faction_id
	record.world_position = world_position
	record.current_health = definition.max_health
	record.is_road_piece = is_road
	record.is_building_piece = is_building
	chunk.construction_feature_records.append(record)
	return true


func _sample_height(world_tile: Vector2i) -> float:
	var base: float = _height_noise.get_noise_2d(world_tile.x, world_tile.y)
	var normalized: float = clampf(base * 0.5 + 0.5, 0.0, 1.0)
	match settings.world_type.world_shape:
		WorldGenerationClasses.WorldTypeProfile.WorldShape.ISLANDS:
			var distance: float = Vector2(world_tile).length() * settings.world_type.continent_scale
			var falloff: float = clampf(distance, 0.0, 1.0)
			normalized *= 1.0 - falloff
		WorldGenerationClasses.WorldTypeProfile.WorldShape.LANDLOCKED:
			normalized = lerpf(normalized, 0.75, 0.25)
		WorldGenerationClasses.WorldTypeProfile.WorldShape.FRACTAL:
			normalized = pow(normalized, 0.85)
		_:
			pass
	return normalized


func _sample_moisture(world_tile: Vector2i) -> float:
	return clampf(_moisture_noise.get_noise_2d(world_tile.x, world_tile.y) * 0.5 + 0.5, 0.0, 1.0)


func _sample_temperature(world_tile: Vector2i) -> float:
	return clampf(_temperature_noise.get_noise_2d(world_tile.x, world_tile.y) * 0.5 + 0.5, 0.0, 1.0)


func _pick_biome(height: float, moisture: float, temperature: float) -> WorldGenerationClasses.TerrainBiome:
	if settings.biome_table.is_empty():
		return WorldGenerationClasses.TerrainBiome.new()

	var best_biome: WorldGenerationClasses.TerrainBiome = settings.biome_table[0]
	var best_score: float = INF
	for biome: WorldGenerationClasses.TerrainBiome in settings.biome_table:
		var mid_height: float = (biome.base_height_min + biome.base_height_max) * 0.5
		var height_score: float = abs(height - mid_height)
		var moisture_target: float = 0.5
		if biome.moisture_noise != null:
			moisture_target = clampf(biome.moisture_noise.frequency * 200.0, 0.0, 1.0)
		var temperature_target: float = 0.5
		if biome.temperature_noise != null:
			temperature_target = clampf(biome.temperature_noise.frequency * 200.0, 0.0, 1.0)
		var moisture_score: float = abs(moisture - moisture_target)
		var temp_score: float = abs(temperature - temperature_target)
		var score: float = height_score + moisture_score + temp_score
		if score < best_score:
			best_score = score
			best_biome = biome
	return best_biome


func _resolve_surface_id(biome: WorldGenerationClasses.TerrainBiome, normalized_height: float) -> int:
	if normalized_height < biome.waterline:
		return int(biome.tile_surface_ids.get("deep_water", 0))
	if normalized_height < biome.beach_line:
		return int(biome.tile_surface_ids.get("sand", 2))
	if normalized_height < biome.hill_line:
		return int(biome.tile_surface_ids.get("grass", 3))
	if normalized_height < biome.mountain_line:
		return int(biome.tile_surface_ids.get("hill", 4))
	return int(biome.tile_surface_ids.get("mountain", 5))


func _generate_natural_features(chunk: WorldGenerationClasses.ChunkWorldLayerData) -> void:
	var spawn_ids: PackedStringArray = world_type_settings.natural_spawn_feature_ids
	var base_chance: float = clampf(world_type_settings.natural_spawn_base_chance, 0.0, 1.0)
	if spawn_ids.is_empty():
		spawn_ids = PackedStringArray(["tree"])
	for local_y: int in settings.chunk_size_tiles:
		for local_x: int in settings.chunk_size_tiles:
			var index: int = local_y * settings.chunk_size_tiles + local_x
			var surface: int = int(chunk.surface_ids[index])
			if surface == 0:
				continue
			var world_x: int = chunk.chunk_coord.x * settings.chunk_size_tiles + local_x
			var world_z: int = chunk.chunk_coord.y * settings.chunk_size_tiles + local_y
			var feature_roll: float = _random01_from_hash([settings.seed, chunk.chunk_coord.x, chunk.chunk_coord.y, world_x, world_z, 9001])
			if feature_roll > base_chance * settings.world_type.forest_density_bias:
				continue
			var feature_id: StringName = _pick_spawn_feature_id(spawn_ids, [settings.seed, world_x, world_z, 9901], &"tree")
			var record: WorldGenerationClasses.FeaturePlacementRecord = WorldGenerationClasses.FeaturePlacementRecord.new()
			record.instance_id = _stable_hash([settings.seed, world_x, world_z, 33])
			record.prototype_id = _resolve_feature_prototype_id(feature_id)
			record.world_position = Vector3(world_x * settings.tile_size_world_units, 0.0, world_z * settings.tile_size_world_units)
			record.yaw_radians = TAU * _random01_from_hash([record.instance_id, 7])
			record.uniform_scale = 0.8 + _random01_from_hash([record.instance_id, 8]) * 0.4
			record.lod_level = 0
			chunk.natural_feature_records.append(record)


func _generate_road_overlay(chunk: WorldGenerationClasses.ChunkWorldLayerData) -> void:
	var road_feature_ids: PackedStringArray = world_type_settings.road_spawn_feature_ids
	var road_side_spawn_chance: float = clampf(world_type_settings.road_side_spawn_chance, 0.0, 1.0)
	for local_y: int in settings.chunk_size_tiles:
		for local_x: int in settings.chunk_size_tiles:
			var world_x: int = chunk.chunk_coord.x * settings.chunk_size_tiles + local_x
			var world_z: int = chunk.chunk_coord.y * settings.chunk_size_tiles + local_y
			var road_noise: float = _random01_from_hash([settings.seed, world_x / 8.0, world_z / 8.0, 4545])
			if road_noise < (0.004 * settings.world_type.road_density_bias):
				var road: WorldGenerationClasses.ConstructionRecord = WorldGenerationClasses.ConstructionRecord.new()
				road.construction_id = _stable_hash([settings.seed, world_x, world_z, 777])
				road.definition_id = &"world_road"
				road.owner_faction_id = -1
				road.world_position = Vector3(world_x * settings.tile_size_world_units, 0.0, world_z * settings.tile_size_world_units)
				road.current_health = 999999.0
				road.is_road_piece = true
				chunk.construction_feature_records.append(road)

				if not road_feature_ids.is_empty():
					var side_roll: float = _random01_from_hash([settings.seed, world_x, world_z, 5151])
					if side_roll <= road_side_spawn_chance:
						var roadside: WorldGenerationClasses.FeaturePlacementRecord = WorldGenerationClasses.FeaturePlacementRecord.new()
						roadside.instance_id = _stable_hash([settings.seed, world_x, world_z, 9123])
						var road_feature_id: StringName = _pick_spawn_feature_id(road_feature_ids, [settings.seed, world_x, world_z, 5222], &"tree")
						roadside.prototype_id = _resolve_feature_prototype_id(road_feature_id)
						roadside.world_position = Vector3(world_x * settings.tile_size_world_units, 0.0, world_z * settings.tile_size_world_units)
						roadside.yaw_radians = TAU * _random01_from_hash([roadside.instance_id, 9])
						roadside.uniform_scale = 0.8 + _random01_from_hash([roadside.instance_id, 10]) * 0.4
						roadside.lod_level = 0
						chunk.natural_feature_records.append(roadside)


func _apply_noise_settings(noise: FastNoiseLite, frequency: float, seed_value: int) -> void:
	noise.seed = seed_value
	noise.frequency = frequency
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.fractal_octaves = 4
	noise.fractal_lacunarity = 2.0
	noise.fractal_gain = 0.5


func _stable_hash(parts: Array) -> int:
	var acc: int = 2166136261
	for part in parts:
		acc = int((acc ^ hash(part)) * 16777619)
	return abs(acc)


func _random01_from_hash(parts: Array) -> float:
	var h: int = _stable_hash(parts)
	return float(h % 100000) / 100000.0


func _resolve_feature_prototype_id(default_id: StringName) -> StringName:
	if _feature_variants_by_id.has(default_id):
		return default_id
	if _feature_variants_by_id.is_empty():
		return default_id
	var first_key: Variant = _feature_variants_by_id.keys()[0]
	return StringName(String(first_key))


func _pick_spawn_feature_id(feature_ids: PackedStringArray, hash_parts: Array, fallback_id: StringName) -> StringName:
	if feature_ids.is_empty():
		return fallback_id
	var index: int = _stable_hash(hash_parts) % feature_ids.size()
	if index < 0 or index >= feature_ids.size():
		return fallback_id
	return StringName(feature_ids[index])


func _color_for_surface(surface: int) -> Color:
	match surface:
		0:
			return Color(0.08, 0.20, 0.60)
		1:
			return Color(0.20, 0.40, 0.80)
		2:
			return Color(0.86, 0.80, 0.52)
		3:
			return Color(0.20, 0.66, 0.28)
		4:
			return Color(0.35, 0.42, 0.25)
		5:
			return Color(0.55, 0.55, 0.58)
		_:
			return Color(1.0, 0.0, 1.0)


func _load_or_create_world_settings() -> WorldGenerationClasses.WorldGenerationSettings:
	if world_type_settings == null and not world_type_settings_path.is_empty():
		var loaded: Resource = load(world_type_settings_path)
		if loaded is WorldGenerationClasses:
			world_type_settings = loaded
	if world_type_settings == null:
		world_type_settings = WorldGenerationClasses.new()
	return _build_settings_from_world_type(world_type_settings)


func _build_settings_from_world_type(config: WorldGenerationClasses) -> WorldGenerationClasses.WorldGenerationSettings:
	var world_type: WorldGenerationClasses.WorldTypeProfile = WorldGenerationClasses.WorldTypeProfile.new()
	world_type.world_shape = config.world_shape
	world_type.continent_scale = config.continent_scale
	world_type.road_density_bias = config.road_density_bias
	world_type.forest_density_bias = config.forest_density_bias

	var default_biome: WorldGenerationClasses.TerrainBiome = _create_biome_from_preset(config.land_preset)

	var generation_settings: WorldGenerationClasses.WorldGenerationSettings = WorldGenerationClasses.WorldGenerationSettings.new()
	generation_settings.seed = config.seed
	generation_settings.chunk_size_tiles = config.chunk_size_tiles
	generation_settings.world_width_chunks = config.world_width_chunks
	generation_settings.world_height_chunks = config.world_height_chunks
	generation_settings.world_type = world_type
	generation_settings.biome_table = [default_biome]
	return generation_settings


func _create_biome_from_preset(preset: WorldGenerationClasses.LandPreset) -> WorldGenerationClasses.TerrainBiome:
	var biome: WorldGenerationClasses.TerrainBiome = WorldGenerationClasses.TerrainBiome.new()
	biome.biome_id = 1
	biome.base_height_min = 0.0
	biome.base_height_max = 1.0

	match preset:
		WorldGenerationClasses.LandPreset.ISLANDS:
			biome.waterline = 0.42
			biome.beach_line = 0.52
			biome.hill_line = 0.72
			biome.mountain_line = 0.88
		WorldGenerationClasses.LandPreset.MOUNTAINS:
			biome.waterline = 0.22
			biome.beach_line = 0.30
			biome.hill_line = 0.52
			biome.mountain_line = 0.66
		WorldGenerationClasses.LandPreset.DESERT:
			biome.waterline = 0.15
			biome.beach_line = 0.75
			biome.hill_line = 0.90
			biome.mountain_line = 0.96
			biome.tile_surface_ids["grass"] = 2
			biome.tile_surface_ids["hill"] = 4
		_:
			biome.waterline = 0.30
			biome.beach_line = 0.35
			biome.hill_line = 0.60
			biome.mountain_line = 0.80

	return biome
