# World generation and simulation data classes for a large streamed top-down world.
# These classes are intentionally data-driven so generation, AI, and player systems can
# share one deterministic pipeline.
extends Resource
class_name WorldGenerationClasses

enum LandPreset {
	PLAINS,
	ISLANDS,
	MOUNTAINS,
	DESERT,
}

@export var seed: int = 1337
@export var chunk_size_tiles: int = 64
@export var world_width_chunks: int = 4
@export var world_height_chunks: int = 3
@export var world_shape: WorldTypeProfile.WorldShape = WorldTypeProfile.WorldShape.CONTINENTAL
@export var continent_scale: float = 0.01
@export var road_density_bias: float = 1.0
@export var forest_density_bias: float = 1.0
@export var land_preset: LandPreset = LandPreset.PLAINS
@export var natural_spawn_feature_ids: PackedStringArray = PackedStringArray(["tree"])
@export var natural_spawn_base_chance: float = 0.03
@export var road_spawn_feature_ids: PackedStringArray = PackedStringArray()
@export var road_side_spawn_chance: float = 0.01


class TerrainNoiseSettings:
	extends Resource

	enum NoiseKind {
		FAST_NOISE_LITE,
		OPEN_SIMPLEX,
		CELLULAR,
		VALUE,
	}

	@export var noise_kind: NoiseKind = NoiseKind.FAST_NOISE_LITE
	@export var frequency: float = 0.001
	@export var octaves: int = 4
	@export var lacunarity: float = 2.0
	@export var gain: float = 0.5
	@export var warp_enabled: bool = false
	@export var warp_frequency: float = 0.003
	@export var warp_amplitude: float = 18.0


class TerrainBiome:
	extends Resource

	@export var biome_id: int = 0
	@export var biome_name: String = "plains"
	@export var base_height_min: float = 0.0
	@export var base_height_max: float = 1.0
	@export var waterline: float = 0.3
	@export var beach_line: float = 0.35
	@export var hill_line: float = 0.6
	@export var mountain_line: float = 0.8

	@export var terrain_noise: TerrainNoiseSettings
	@export var moisture_noise: TerrainNoiseSettings
	@export var temperature_noise: TerrainNoiseSettings

	@export var movement_speed_multiplier: float = 1.0
	@export var road_bonus_multiplier: float = 1.15

	@export var tile_surface_ids := {
		"deep_water": 0,
		"shallow_water": 1,
		"sand": 2,
		"grass": 3,
		"hill": 4,
		"mountain": 5,
	}


class WorldTypeProfile:
	extends Resource

	enum WorldShape {
		CONTINENTAL,
		ISLANDS,
		FRACTAL,
		LANDLOCKED,
	}

	@export var world_shape: WorldShape = WorldShape.CONTINENTAL
	@export var ocean_coverage: float = 0.45
	@export var continent_scale: float = 0.001
	@export var erosion_strength: float = 0.4
	@export var ridge_strength: float = 0.25
	@export var road_density_bias: float = 1.0
	@export var forest_density_bias: float = 1.0


class WorldLODSettings:
	extends Resource

	@export var zoom_thresholds: PackedFloat32Array = PackedFloat32Array([0.75, 1.35, 2.5])
	@export var cell_scale_per_lod: PackedInt32Array = PackedInt32Array([1, 2, 4, 8])
	@export var simulation_rate_per_lod: PackedFloat32Array = PackedFloat32Array([1.0, 0.5, 0.2, 0.05])


class WorldGenerationSettings:
	extends Resource

	enum WorldSizeMode {
		FINITE,
		INFINITE,
	}

	@export var seed: int = 1
	@export var world_size_mode: WorldSizeMode = WorldSizeMode.FINITE
	@export var chunk_size_tiles: int = 128
	@export var world_width_chunks: int = 64
	@export var world_height_chunks: int = 64
	@export var tile_size_world_units: float = 1.0
	@export var world_type: WorldTypeProfile
	@export var lod_settings: WorldLODSettings
	@export var biome_table: Array[TerrainBiome] = []


class FeaturePrototype:
	extends Resource

	enum RenderKind {
		MESH_3D,
		BILLBOARD,
	}

	@export var prototype_id: StringName
	@export var render_kind: RenderKind = RenderKind.MESH_3D
	@export var scene_path: String = ""
	@export var mesh_path: String = ""
	@export var material_override_path: String = ""
	@export var can_promote_to_interactive: bool = true
	@export var collision_radius: float = 0.75
	@export var lod_min: int = 0
	@export var lod_max: int = 3


class FeaturePlacementRecord:
	extends RefCounted

	var instance_id: int = -1
	var prototype_id: StringName
	var world_position: Vector3 = Vector3.ZERO
	var yaw_radians: float = 0.0
	var uniform_scale: float = 1.0
	var lod_level: int = 0
	var state_flags: int = 0
	var owner_faction_id: int = -1


class InteractableDefinition:
	extends Resource

	enum InteractionKind {
		NONE,
		GATHER,
		HARVEST,
		BUILD,
		REPAIR,
		UPGRADE,
		DEMOLISH,
		ATTACK,
	}

	@export var definition_id: StringName
	@export var display_name: String = ""
	@export var max_health: float = 100.0
	@export var allowed_actions: PackedInt32Array = PackedInt32Array([
		InteractionKind.GATHER,
		InteractionKind.BUILD,
		InteractionKind.REPAIR,
	])
	@export var result_definition_on_destroy: StringName
	@export var movement_cost_modifier: float = 1.0
	@export var supports_player_owner: bool = true
	@export var supports_enemy_owner: bool = true


class BuildPermissionProfile:
	extends Resource

	@export var profile_id: StringName
	@export var can_place_roads: bool = true
	@export var can_place_buildings: bool = true
	@export var can_upgrade: bool = true
	@export var allowed_definition_ids: PackedStringArray = PackedStringArray()

	func can_place_definition(definition_id: StringName) -> bool:
		if allowed_definition_ids.is_empty():
			return true
		return allowed_definition_ids.has(String(definition_id))


class FactionConstructionRules:
	extends Resource

	@export var faction_id: int = 0
	@export var faction_name: String = "neutral"
	@export var build_permissions: BuildPermissionProfile
	@export var interact_permissions: BuildPermissionProfile


class ConstructionRecord:
	extends RefCounted

	var construction_id: int = -1
	var definition_id: StringName
	var owner_faction_id: int = -1
	var world_position: Vector3 = Vector3.ZERO
	var world_rotation_y: float = 0.0
	var current_health: float = 100.0
	var is_road_piece: bool = false
	var is_building_piece: bool = false


class ChunkWorldLayerData:
	extends RefCounted

	var chunk_coord: Vector2i = Vector2i.ZERO
	var surface_ids: PackedByteArray = PackedByteArray()
	var biome_ids: PackedByteArray = PackedByteArray()
	var height_values: PackedFloat32Array = PackedFloat32Array()
	var natural_feature_records: Array[FeaturePlacementRecord] = []
	var construction_feature_records: Array[ConstructionRecord] = []


class InteractionCommand:
	extends RefCounted

	var actor_unit_id: int = -1
	var target_instance_id: int = -1
	var action: InteractableDefinition.InteractionKind = InteractableDefinition.InteractionKind.NONE
	var interaction_position: Vector3 = Vector3.ZERO


class InteractionResult:
	extends RefCounted

	var success: bool = false
	var message: String = ""
	var modified_instance_id: int = -1
	var spawned_definition_id: StringName


class TerrainQueryService:
	extends RefCounted

	# This class is a contract holder for future implementation.
	# Gameplay systems query terrain and ownership layer data through this API.
	func get_surface_id_at_world_position(_world_position: Vector3) -> int:
		return -1

	func get_biome_id_at_world_position(_world_position: Vector3) -> int:
		return -1

	func get_construction_at_world_position(_world_position: Vector3) -> ConstructionRecord:
		return null
