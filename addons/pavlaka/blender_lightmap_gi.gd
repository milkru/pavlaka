@tool
# red monochrome Blender mark to match Godot's other 3D node icons. Custom @icon icons aren't
# auto-tinted, so the red is baked into this file (the colored blender-logo.svg is still used
# for the toolbar button / progress strip).
@icon("res://addons/pavlaka/blender-node-icon.svg")
class_name BlenderLightmapGI
extends LightmapGI
## A LightmapGI whose lighting is baked externally by Blender (Cycles) via the pavlaka
## plugin, then assigned back as native LightmapGIData.
##
## Select this node in the 3D editor and press "Bake with Blender" in the toolbar — it
## behaves like the built-in LightmapGI bake button. The inherited LightmapGI bake
## settings (Quality, Bounces, Denoiser, etc.) are NOT used; baking is driven by the
## "Blender Bake" parameters below.

# Bake sizing reuses LightmapGI's own inherited properties (kept visible via
# _validate_property), so they appear under Tweaks like native:
#  - max_texture_size: caps each atlas page's dimensions. Pages grow to fit their content but
#    never exceed this, opening a new page when they would (multi-page like the native baker).
#  - texel_scale: density multiplier. Each mesh's lightmap chunk is sized
#    sqrt(world surface area) * BASE_DENSITY * texel_scale, so density is uniform across the
#    scene (no stretching). Higher = sharper / more texels / more pages.
#  - quality (Low/Medium/High/Ultra): maps to Cycles samples in the baker.
# The Environment section (Mode / Custom Sky / Custom Color / Custom Energy) is LightmapGI's
# own too; we keep it visible and read it in the baker. Mode: 0 Disabled, 1 Scene, 2 Custom
# Sky, 3 Custom Color.

@export_group("Blender Bake")
## Render the bake on the GPU if a compute device is available (much faster), otherwise fall
## back to the CPU. On by default; turn off if GPU baking is unstable on your machine or you
## want the most CPU-consistent result.
@export var use_gpu: bool = true
## Pixels the baked result is dilated past each UV island edge. Higher reduces dark seams and
## bleeding between charts at the cost of some atlas space; too low can show black edges.
@export_range(0, 64) var bake_margin: int = 16
## Compress the baked lightmap textures to save GPU memory.
##
## Off (default): lossless. Each atlas page keeps its exact content fit size and never
## exceeds Max Texture Size. Best quality and no wasted space, but the most VRAM.
##
## On: GPU texture compression (BC6H), roughly 4x less VRAM. Costs: each page is rounded up
## to a power of two, so some atlas space is wasted and a page can end up larger than Max
## Texture Size; and the HDR compression can introduce slight color banding on smooth
## gradients. Prefer this only when lightmap VRAM is a real concern.
@export var compress_lightmaps: bool = false

@export_group("Lights")
## Multiplier applied to each Static light's own energy during the bake. Only lights with
## Bake Mode = Static contribute; their actual energy and color are used (×this scale).
## Tune this if the baked brightness doesn't match the in-editor lighting.
@export var light_energy_scale: float = 1.0


func get_bake_opts() -> Dictionary:
	return {
		"max_texture_size": max_texture_size, # inherited LightmapGI property; caps page size
		"texel_scale": texel_scale, # inherited LightmapGI property; density multiplier
		"quality": quality, # inherited LightmapGI property; mapped to samples in the baker
		"compress": compress_lightmaps,
		"use_gpu": use_gpu,
		"bounces": bounces, # inherited LightmapGI property; Cycles diffuse bounces
		"bake_margin": bake_margin,
		"denoise": use_denoiser, # inherited LightmapGI property
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


# Inherited LightmapGI properties we keep visible: the Environment section (it's the one we
# reuse), the Quality dropdown, and the Data > Light Data slot (the baked .lmbake, shown like
# native so it can be inspected/cleared). "Data" is the group header for light_data.
const _KEEP_VISIBLE := {
	"quality": true, "texel_scale": true, "max_texture_size": true, "bounces": true,
	"use_denoiser": true,
	"environment_mode": true, "environment_custom_sky": true,
	"environment_custom_color": true, "environment_custom_energy": true,
	"Data": true, "light_data": true,
}


func _validate_property(property: Dictionary) -> void:
	if _inherited_props.is_empty():
		for p in ClassDB.class_get_property_list("LightmapGI", true):
			_inherited_props[p.name] = true
	if _inherited_props.has(property.name) and not _KEEP_VISIBLE.has(property.name):
		property.usage &= ~PROPERTY_USAGE_EDITOR
