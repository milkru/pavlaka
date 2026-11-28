@tool
class_name PavlakaLightGroups
extends Resource
## The light groups of a bake: light that changes while the game runs (flickering, switched).
## A light group is the lights and emissive surfaces whose node has the metadata "light_group"
## (its name). pavlaka bakes them out of the main lightmap, each group on its own, and keeps the
## tiles of the lightmap each group lights. BlenderLightmapGI adds them back to the lightmap at
## the strength set by set_light_group_energy(), and scales the group's lights and emission to match.

## The side of a tile, in texels: a group keeps its light in the tiles where it could show.
const TILE := 16

## The groups' names.
@export var names: PackedStringArray
## The bake's page size, in texels: where `cells` are (an imported page may be stored scaled).
@export var page_size: Vector2i
## Every group's lit tiles, packed (one layer).
@export var tiles: TextureLayered
## Per lightmap tile that a group lights: page, x, y, width, height (texels), first part, parts.
@export var cells: PackedInt32Array
## Per part (a group's light on a cell): group index, x, y of its tile in `tiles`.
@export var parts: PackedInt32Array
## Per group: the paths (from the BlenderLightmapGI) of its lights.
@export var lights: Array
## Per group: [path, surface] of its emissive mesh surfaces.
@export var surfaces: Array


func group_count() -> int:
	return names.size()
