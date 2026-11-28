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
## smooth gradients can band slightly. Use only when lightmap VRAM is a real concern. With light
## groups the GPU also keeps two uncompressed copies of each page, so it saves little there.
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

## The bake's light groups (light that changes while the game runs), or null. A light or a mesh
## joins a group by its metadata "light_group" (the group's name); see PavlakaLightGroups.
@export_storage var light_groups: PavlakaLightGroups

var _composer: PavlakaGroupComposer
## A bake is running (set by PavlakaBaker): the light groups stay off, the preview shows the main
## bake alone.
var baking := false
var _energies := PackedFloat32Array()
var _dirty := false
var _scaled := [] # per group: [[Light3D, energy], ...] and [[material copy, emission energy], ...]


## The light groups' names.
func get_light_group_names() -> PackedStringArray:
	return light_groups.names if light_groups else PackedStringArray()


## Sets how strong a light group is: 1 as baked, 0 off. Scales its baked light, its emissive
## surfaces and its lights (as they light anything live). The editor always shows 1.
func set_light_group_energy(group: StringName, energy: float) -> void:
	var i := get_light_group_names().find(group)
	if i < 0 or i >= _energies.size() or is_equal_approx(_energies[i], energy):  # float32 storage
		return
	_energies[i] = energy
	_dirty = true
	if i < _scaled.size():
		for pair in _scaled[i][0]:
			(pair[0] as Light3D).light_energy = pair[1] * energy
		for pair in _scaled[i][1]:
			(pair[0] as BaseMaterial3D).emission_energy_multiplier = pair[1] * energy


func get_light_group_energy(group: StringName) -> float:
	var i := get_light_group_names().find(group)
	return _energies[i] if i >= 0 and i < _energies.size() else 0.0


## Stops adding the light groups (before a bake changes the light data); restart_light_groups()
## starts again.
func stop_light_groups() -> void:
	if _composer:
		_composer.stop()
		_composer = null
	set_process(false)


func restart_light_groups() -> void:
	stop_light_groups()
	if baking:
		return
	if light_groups == null or light_groups.group_count() == 0 or light_data == null:
		return
	if _energies.size() != light_groups.group_count():
		_energies.resize(light_groups.group_count())
		_energies.fill(1.0)
	if Engine.is_editor_hint():
		_energies.fill(1.0)
	_composer = PavlakaGroupComposer.new()
	if not _composer.start(light_data, light_groups, _energies):
		_composer = null
		push_warning("pavlaka: light groups need the Forward+ or Mobile renderer")
		return
	set_process(true)


func _process(_delta: float) -> void:
	if _dirty and _composer:
		_dirty = false
		_composer.update(_energies)


func _notification(what: int) -> void:
	if what == NOTIFICATION_ENTER_TREE:
		_apply_baked_bounds()
		if is_node_ready():  # back in the tree (an editor tab switch, a reparent): EXIT_TREE stopped it
			restart_light_groups()
	elif what == NOTIFICATION_READY:
		if not Engine.is_editor_hint():
			_scale_groups()
		restart_light_groups()
	elif what == NOTIFICATION_EXIT_TREE:
		stop_light_groups()


# The game's copies of each group's lights and emissive materials, so energy can scale them.
# Not in the editor: the scene would save them.
func _scale_groups() -> void:
	_scaled.clear()
	if light_groups == null:
		return
	var copies := {} # "<material id>:<group>" -> copy
	for g in light_groups.group_count():
		var lights := []
		for path in (light_groups.lights[g] if g < light_groups.lights.size() else []):
			var l := get_node_or_null(path) as Light3D
			if l:
				lights.append([l, l.light_energy])
		var mats := []
		for entry in (light_groups.surfaces[g] if g < light_groups.surfaces.size() else []):
			var mi := get_node_or_null(entry[0]) as MeshInstance3D
			if mi == null or mi.mesh == null or int(entry[1]) >= mi.mesh.get_surface_count():
				continue
			var mat := mi.get_active_material(int(entry[1])) as BaseMaterial3D
			if mat == null:
				continue
			var key := "%d:%d" % [mat.get_instance_id(), g]
			if not copies.has(key):
				copies[key] = mat.duplicate()
				mats.append([copies[key], mat.emission_energy_multiplier])
			mi.set_surface_override_material(int(entry[1]), copies[key])
		_scaled.append([lights, mats])


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
