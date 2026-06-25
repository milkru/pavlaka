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
## Size (longest side, px) of the single packed lightmap atlas for the whole scene. Each
## mesh gets a share of the atlas proportional to its world-space surface area; the packed
## sheet is then scaled so its longest side equals this (aspect preserved).
@export var lightmap_size: int = 2048
# Quality (Low/Medium/High/Ultra) reuses LightmapGI's own inherited "quality" property and
# maps to Cycles samples in the baker (see _validate_property / get_bake_opts).

# NOTE: the Environment section (Mode / Custom Sky / Custom Color / Custom Energy) is
# LightmapGI's own — we don't redefine it, just keep it visible (see _validate_property)
# and read it in the baker. Mode values: 0 Disabled, 1 Scene, 2 Custom Sky, 3 Custom Color.

@export_group("Lights")
## Multiplier applied to each Static light's own energy during the bake. Only lights with
## Bake Mode = Static contribute; their actual energy and color are used (×this scale).
## Tune this if the baked brightness doesn't match the in-editor lighting.
@export var light_energy_scale: float = 1.0


func get_bake_opts() -> Dictionary:
	return {
		"out_dir": output_dir,
		"lightmap_size": lightmap_size,
		"quality": quality, # inherited LightmapGI property; mapped to samples in the baker
		"light_energy_scale": light_energy_scale,
		# these are LightmapGI's own inherited Environment properties
		"environment_mode": environment_mode,
		"environment_custom_sky": environment_custom_sky,
		"environment_custom_color": environment_custom_color,
		"environment_custom_energy": environment_custom_energy,
	}


# World-space bounds of the bake, stored (not shown) so we can re-apply them to the
# RenderingServer on load. We keep the LightmapGIData's probe points EMPTY (so no probe
# gizmo is drawn), but the lightmap instance still needs a non-empty AABB or it gets
# culled — so we set the bounds directly here instead of via capture data.
@export_storage var baked_bounds := AABB()


func _notification(what: int) -> void:
	if what == NOTIFICATION_ENTER_TREE:
		_apply_baked_bounds()


func _apply_baked_bounds() -> void:
	if light_data != null and baked_bounds.size != Vector3.ZERO:
		RenderingServer.lightmap_set_probe_bounds(light_data.get_rid(), baked_bounds)


# Hide the inherited LightmapGI properties (Quality, Bounces, Directional, etc.) — they
# don't apply to a Blender bake and only confuse. Keep them stored (so light_data still
# serializes) but out of the inspector.
var _inherited_props: Dictionary = {}


# LightmapGI's Environment properties are kept visible (it's the section we DO want);
# its own _validate_property still hides the custom sky/color by mode.
const _KEEP_VISIBLE := {
	"quality": true,
	"environment_mode": true, "environment_custom_sky": true,
	"environment_custom_color": true, "environment_custom_energy": true,
}


func _validate_property(property: Dictionary) -> void:
	if _inherited_props.is_empty():
		for p in ClassDB.class_get_property_list("LightmapGI", true):
			_inherited_props[p.name] = true
	if _inherited_props.has(property.name) and not _KEEP_VISIBLE.has(property.name):
		property.usage &= ~PROPERTY_USAGE_EDITOR
