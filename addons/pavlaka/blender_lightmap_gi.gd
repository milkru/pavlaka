@tool
class_name BlenderLightmapGI
extends LightmapGI
## A LightmapGI baked externally by Blender (Cycles) via the pavlaka plugin, assigned back as
## native LightmapGIData. Select the node and press "Bake Lightmaps" in the 3D toolbar. The bake
## reads the Tweaks below plus a few reused inherited settings (Quality, Bounces, Denoiser, Texel
## Scale, Max Texture Size, Environment); other inherited LightmapGI settings are hidden.

# Inherited LightmapGI properties the baker reuses, kept visible (see _KEEP_VISIBLE):
#  - max_texture_size: per-page atlas cap; pages open as needed (multi-page, like native).
#  - texel_scale: density multiplier (chunk px = sqrt(world area) * BASE_DENSITY * texel_scale).
#  - quality (Low/Medium/High/Ultra): maps to Cycles samples.
#  - Environment (Mode / Custom Sky / Custom Color / Custom Energy): 0 Off, 1 Scene, 2 Sky, 3 Color.

@export_group("Tweaks")
## Render on the GPU if available (much faster), else the CPU. Turn off if GPU baking is
## unstable or you want the most CPU-consistent result.
@export var use_gpu: bool = true
## Pixels the baked result is dilated past each UV island edge. Higher reduces dark seams and
## bleeding between charts at the cost of some atlas space; too low can show black edges.
@export_range(0, 64) var bake_margin: int = 16
## Clamp indirect sample brightness to kill fireflies the denoiser can't remove. 0 = off; a
## small value like 10 cleans up noisy interiors at a tiny cost in indirect brightness.
@export_range(0.0, 50.0, 0.1, "or_greater") var indirect_clamp: float = 0.0
## Compress the baked lightmaps (BC6H) to save GPU memory.
##
## Off (default): lossless, exact-fit pages that respect Max Texture Size. Best quality, most VRAM.
## On: ~4x less VRAM, but pages round up to a power of two (may exceed Max Texture Size) and
## smooth gradients can band slightly. Use only when lightmap VRAM is a real concern.
@export var compress_lightmaps: bool = false


func get_bake_opts() -> Dictionary:
	return {
		"max_texture_size": max_texture_size, # inherited; per-page atlas cap
		"texel_scale": texel_scale, # inherited; density multiplier
		"quality": quality, # inherited; mapped to Cycles samples
		"compress": compress_lightmaps,
		"use_gpu": use_gpu,
		"bounces": bounces, # inherited; Cycles diffuse bounces
		"bake_margin": bake_margin,
		"indirect_clamp": indirect_clamp,
		"denoise": use_denoiser, # inherited
		# inherited Environment section
		"environment_mode": environment_mode,
		"environment_custom_sky": environment_custom_sky,
		"environment_custom_color": environment_custom_color,
		"environment_custom_energy": environment_custom_energy,
	}


# Bake bounds, stored to re-apply on load. Probe points stay empty (no gizmo), but the lightmap
# instance needs a non-empty AABB or it's culled, so we set bounds directly, not via capture data.
@export_storage var baked_bounds := AABB()


func _notification(what: int) -> void:
	if what == NOTIFICATION_ENTER_TREE:
		_apply_baked_bounds()


func _apply_baked_bounds() -> void:
	if light_data != null and baked_bounds.size != Vector3.ZERO:
		RenderingServer.lightmap_set_probe_bounds(light_data.get_rid(), baked_bounds)


# Inherited LightmapGI properties hidden from the inspector (they don't apply here) but still
# stored, so light_data keeps serializing. Filled lazily on first _validate_property.
var _inherited_props: Dictionary = {}


# Inherited properties kept visible: the reused bake/Environment settings, plus the Data >
# Light Data slot (the baked .lmbake, shown like native). "Data" is light_data's group header.
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
