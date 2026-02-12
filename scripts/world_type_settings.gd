extends Resource
class_name WorldTypeSettings

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

@export var world_shape: WorldGenerationClasses.WorldTypeProfile.WorldShape = WorldGenerationClasses.WorldTypeProfile.WorldShape.CONTINENTAL
@export var continent_scale: float = 0.01
@export var road_density_bias: float = 1.0
@export var forest_density_bias: float = 1.0

@export var land_preset: LandPreset = LandPreset.PLAINS
