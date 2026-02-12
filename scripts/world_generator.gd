# Deterministic chunk generator that uses the world-generation data contracts.
extends RefCounted

const WorldData = WorldGenerationClasses

var settings: WorldData.WorldGenerationSettings
var faction_rules_by_id: Dictionary = {}

var _height_noise := FastNoiseLite.new()
var _moisture_noise := FastNoiseLite.new()
var _temperature_noise := FastNoiseLite.new()

func setup(new_settings: WorldData.WorldGenerationSettings, faction_rules: Array[WorldData.FactionConstructionRules] = []) -> void:
	settings = new_settings
	faction_rules_by_id.clear()
	for rules in faction_rules:
		faction_rules_by_id[rules.faction_id] = rules
	_apply_noise_settings(_height_noise, settings.world_type.continent_scale, settings.seed)
	_apply_noise_settings(_moisture_noise, settings.world_type.continent_scale * 1.8, settings.seed + 404)
	_apply_noise_settings(_temperature_noise, settings.world_type.continent_scale * 1.2, settings.seed + 909)


func generate_chunk(chunk_coord: Vector2i) -> WorldData.ChunkWorldLayerData:
	assert(settings != null, "WorldGenerator.setup must be called before generate_chunk.")
	var chunk: WorldData.ChunkWorldLayerData = WorldData.ChunkWorldLayerData.new()
	chunk.chunk_coord = chunk_coord
	var tile_count := settings.chunk_size_tiles * settings.chunk_size_tiles
	chunk.surface_ids.resize(tile_count)
	chunk.biome_ids.resize(tile_count)
	chunk.height_values.resize(tile_count)

	for local_y in settings.chunk_size_tiles:
		for local_x in settings.chunk_size_tiles:
			var world_tile := Vector2i(
				chunk_coord.x * settings.chunk_size_tiles + local_x,
				chunk_coord.y * settings.chunk_size_tiles + local_y
			)
			var index := local_y * settings.chunk_size_tiles + local_x
			var normalized_height := _sample_height(world_tile)
			var moisture := _sample_moisture(world_tile)
			var temperature := _sample_temperature(world_tile)
			var biome := _pick_biome(normalized_height, moisture, temperature)
			chunk.height_values[index] = normalized_height
			chunk.biome_ids[index] = clampi(biome.biome_id, 0, 255)
			chunk.surface_ids[index] = clampi(_resolve_surface_id(biome, normalized_height), 0, 255)

	_generate_natural_features(chunk)
	_generate_road_overlay(chunk)
	return chunk


func try_place_construction(chunk: WorldData.ChunkWorldLayerData, owner_faction_id: int, definition: WorldData.InteractableDefinition, world_position: Vector3, is_road: bool, is_building: bool) -> bool:
	if not faction_rules_by_id.has(owner_faction_id):
		return false
	var rules: WorldData.FactionConstructionRules = faction_rules_by_id[owner_faction_id]
	if rules.build_permissions == null:
		return false
	if is_road and not rules.build_permissions.can_place_roads:
		return false
	if is_building and not rules.build_permissions.can_place_buildings:
		return false
	if not rules.build_permissions.can_place_definition(definition.definition_id):
		return false

	var record: WorldData.ConstructionRecord = WorldData.ConstructionRecord.new()
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
	var base := _height_noise.get_noise_2d(world_tile.x, world_tile.y)
	var normalized := clampf(base * 0.5 + 0.5, 0.0, 1.0)
	match settings.world_type.world_shape:
		WorldData.WorldTypeProfile.WorldShape.ISLANDS:
			var distance := Vector2(world_tile).length() * settings.world_type.continent_scale
			var falloff := clampf(distance, 0.0, 1.0)
			normalized *= 1.0 - falloff
		WorldData.WorldTypeProfile.WorldShape.LANDLOCKED:
			normalized = lerpf(normalized, 0.75, 0.25)
		WorldData.WorldTypeProfile.WorldShape.FRACTAL:
			normalized = pow(normalized, 0.85)
		_:
			pass
	return normalized


func _sample_moisture(world_tile: Vector2i) -> float:
	return clampf(_moisture_noise.get_noise_2d(world_tile.x, world_tile.y) * 0.5 + 0.5, 0.0, 1.0)


func _sample_temperature(world_tile: Vector2i) -> float:
	return clampf(_temperature_noise.get_noise_2d(world_tile.x, world_tile.y) * 0.5 + 0.5, 0.0, 1.0)


func _pick_biome(height: float, moisture: float, temperature: float) -> WorldData.TerrainBiome:
	if settings.biome_table.is_empty():
		return WorldData.TerrainBiome.new()

	var best_biome: WorldData.TerrainBiome = settings.biome_table[0]
	var best_score: float = INF
	for biome in settings.biome_table:
		var mid_height := (biome.base_height_min + biome.base_height_max) * 0.5
		var height_score := abs(height - mid_height)
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


func _resolve_surface_id(biome: WorldData.TerrainBiome, normalized_height: float) -> int:
	if normalized_height < biome.waterline:
		return int(biome.tile_surface_ids.get("deep_water", 0))
	if normalized_height < biome.beach_line:
		return int(biome.tile_surface_ids.get("sand", 2))
	if normalized_height < biome.hill_line:
		return int(biome.tile_surface_ids.get("grass", 3))
	if normalized_height < biome.mountain_line:
		return int(biome.tile_surface_ids.get("hill", 4))
	return int(biome.tile_surface_ids.get("mountain", 5))


func _generate_natural_features(chunk: WorldData.ChunkWorldLayerData) -> void:
	for local_y in settings.chunk_size_tiles:
		for local_x in settings.chunk_size_tiles:
			var index := local_y * settings.chunk_size_tiles + local_x
			var surface := int(chunk.surface_ids[index])
			if surface == 0:
				continue
			var world_x := chunk.chunk_coord.x * settings.chunk_size_tiles + local_x
			var world_z := chunk.chunk_coord.y * settings.chunk_size_tiles + local_y
			var feature_roll := _random01_from_hash([settings.seed, chunk.chunk_coord.x, chunk.chunk_coord.y, world_x, world_z, 9001])
			if feature_roll > 0.03 * settings.world_type.forest_density_bias:
				continue
			var record: WorldData.FeaturePlacementRecord = WorldData.FeaturePlacementRecord.new()
			record.instance_id = _stable_hash([settings.seed, world_x, world_z, 33])
			record.prototype_id = &"tree"
			record.world_position = Vector3(world_x * settings.tile_size_world_units, 0.0, world_z * settings.tile_size_world_units)
			record.yaw_radians = TAU * _random01_from_hash([record.instance_id, 7])
			record.uniform_scale = 0.8 + _random01_from_hash([record.instance_id, 8]) * 0.4
			record.lod_level = 0
			chunk.natural_feature_records.append(record)


func _generate_road_overlay(chunk: WorldData.ChunkWorldLayerData) -> void:
	for local_y in settings.chunk_size_tiles:
		for local_x in settings.chunk_size_tiles:
			var world_x := chunk.chunk_coord.x * settings.chunk_size_tiles + local_x
			var world_z := chunk.chunk_coord.y * settings.chunk_size_tiles + local_y
			var road_noise := _random01_from_hash([settings.seed, world_x / 8, world_z / 8, 4545])
			if road_noise < (0.004 * settings.world_type.road_density_bias):
				var road: WorldData.ConstructionRecord = WorldData.ConstructionRecord.new()
				road.construction_id = _stable_hash([settings.seed, world_x, world_z, 777])
				road.definition_id = &"world_road"
				road.owner_faction_id = -1
				road.world_position = Vector3(world_x * settings.tile_size_world_units, 0.0, world_z * settings.tile_size_world_units)
				road.current_health = 999999.0
				road.is_road_piece = true
				chunk.construction_feature_records.append(road)


func _apply_noise_settings(noise: FastNoiseLite, frequency: float, seed_value: int) -> void:
	noise.seed = seed_value
	noise.frequency = frequency
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.fractal_octaves = 4
	noise.fractal_lacunarity = 2.0
	noise.fractal_gain = 0.5


func _stable_hash(parts: Array) -> int:
	var acc := 2166136261
	for part in parts:
		acc = int((acc ^ hash(part)) * 16777619)
	return abs(acc)


func _random01_from_hash(parts: Array) -> float:
	var h := _stable_hash(parts)
	return float(h % 100000) / 100000.0
