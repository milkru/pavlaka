@tool
class_name LightmapBlenderGI
extends LightmapGI
## A LightmapGI whose lighting is baked externally by Blender (Cycles) via the pavlaka
## plugin, then assigned back as native LightmapGIData.
##
## Select this node in the 3D editor and press "Bake with Blender" in the toolbar — it
## behaves like the built-in LightmapGI bake button. The inherited LightmapGI bake
## settings (Quality, Bounces, Denoiser, etc.) are NOT used; baking is driven by the
## "Blender Bake" parameters below.

@export_group("Blender Bake")
## Where the baked .lmbake and EXR slices are written.
@export_dir var output_dir: String = "res://lightmaps"
## Resolution of each per-mesh lightmap slice (square).
@export var atlas_size: int = 512
## Cycles samples per bake. The OIDN denoise pass cleans up remaining noise.
@export var samples: int = 256

@export_group("Ambient Dome")
## Ambient/sky dome brightness (white * energy). With no scene lights this alone gives
## an ambient-occlusion bake; with a sun it acts as fill light.
@export var ambient_energy: float = 0.2
## Ambient/sky dome color.
@export var ambient_color: Color = Color.WHITE

@export_group("Lights")
## Energy applied to DirectionalLight (sun) lights during the bake (POC stand-in until
## proper Godot->Cycles light-energy calibration exists).
@export var sun_energy: float = 4.0


func get_bake_opts() -> Dictionary:
	return {
		"out_dir": output_dir,
		"atlas": atlas_size,
		"samples": samples,
		"ambient": ambient_energy,
		"ambient_color": ambient_color,
		"sun_energy": sun_energy,
	}


# Hide the inherited LightmapGI properties (Quality, Bounces, Directional, etc.) — they
# don't apply to a Blender bake and only confuse. Keep them stored (so light_data still
# serializes) but out of the inspector.
var _inherited_props: Dictionary = {}


func _validate_property(property: Dictionary) -> void:
	if _inherited_props.is_empty():
		for p in ClassDB.class_get_property_list("LightmapGI", true):
			_inherited_props[p.name] = true
	if _inherited_props.has(property.name):
		property.usage &= ~PROPERTY_USAGE_EDITOR
