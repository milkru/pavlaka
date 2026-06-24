@tool
class_name PavlakaBaker
extends RefCounted
## Core pavlaka pipeline (editor-context): gather a scene's static lightmapped meshes,
## export to glb, bake in Blender headless, import the per-mesh EXR slices, build a
## LightmapGIData, save it as .lmbake, and assign it to a LightmapGI node.
##
## Every stage here is the proven POC pipeline; this just orchestrates it. Designed to be
## callable headlessly (no UI) so it can be verified end-to-end.

# bake.py ships inside the addon (addons live at the fixed res://addons/<name>/ path),
# so the plugin is self-contained: copying addons/pavlaka/ into any project is enough.
const BAKE_SCRIPT := "res://addons/pavlaka/bake.py"

const DEFAULTS := {
	"out_dir": "res://lightmaps/",
	"atlas": 512,
	"sun_energy": 4.0,
	"ambient": 0.2,
	"samples": 256,
}


class Target:
	var node: MeshInstance3D
	var path: NodePath  # relative to the LightmapGI node
	var name: String


## Bake `lm`'s scene. Returns OK or an error code; messages go to the editor log.
static func bake(root: Node3D, lm: LightmapGI, blender_path: String, opts: Dictionary = {}) -> int:
	var cfg := DEFAULTS.duplicate()
	for k in opts:
		cfg[k] = opts[k]

	if blender_path.is_empty() or not FileAccess.file_exists(blender_path):
		push_error("pavlaka: Blender executable not found: '%s'" % blender_path)
		return ERR_FILE_NOT_FOUND

	# 1. collect static meshes that carry a UV2 (the lightmap UV Godot owns)
	var targets: Array[Target] = []
	_collect(root, lm, targets)
	if targets.is_empty():
		push_error("pavlaka: no static MeshInstance3D with UV2 found under '%s'" % root.name)
		return ERR_INVALID_DATA
	print("pavlaka: %d lightmap target(s): %s" % [targets.size(),
		targets.map(func(t): return t.name)])

	# 2. export the whole scene (geometry + lights) to a temp glb for Blender
	DirAccess.make_dir_recursive_absolute("user://pavlaka_tmp")
	var glb_abs := ProjectSettings.globalize_path("user://pavlaka_tmp/scene.glb")
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_scene(root, state)
	if err != OK:
		push_error("pavlaka: glTF append failed (%d)" % err)
		return err
	err = doc.write_to_filesystem(state, glb_abs)
	if err != OK:
		push_error("pavlaka: glTF write failed (%d)" % err)
		return err

	# 3. run Blender headless to bake
	var out_dir: String = cfg["out_dir"]
	DirAccess.make_dir_recursive_absolute(out_dir)
	var args := PackedStringArray([
		"--background", "--python", ProjectSettings.globalize_path(BAKE_SCRIPT), "--",
		glb_abs, ProjectSettings.globalize_path(out_dir),
		str(cfg["atlas"]), str(cfg["sun_energy"]), str(cfg["ambient"]), str(cfg["samples"]),
	])
	var output: Array = []
	print("pavlaka: running Blender...")
	var code := OS.execute(blender_path, args, output, true)
	# always surface Blender's output so bake errors are visible
	print("pavlaka: --- Blender output (exit %d) ---\n%s\npavlaka: --- end ---" % [code, "\n".join(output)])
	if code != 0:
		push_error("pavlaka: Blender failed (exit %d) — see output above" % code)
		return FAILED

	# 4. read bake metadata
	var meta_path := out_dir.path_join("baked.json")
	var meta_str := FileAccess.get_file_as_string(meta_path)
	if meta_str.is_empty():
		push_error("pavlaka: missing bake metadata at %s — Blender exited 0 but wrote no result (see output above)" % meta_path)
		return ERR_FILE_CANT_READ
	var meta: Dictionary = JSON.parse_string(meta_str)
	var baked_meshes: Array = meta.get("meshes", [])

	# 5. import each per-mesh EXR slice as a CompressedTexture2DArray
	var efs := EditorInterface.get_resource_filesystem()
	var slice_paths := PackedStringArray()
	for m in baked_meshes:
		var p: String = out_dir.path_join("baked_%d.exr" % int(m["slice_index"]))
		_write_exr_import(p)
		slice_paths.append(p)
		efs.update_file(p)
	efs.reimport_files(slice_paths)

	var textures: Array = []
	textures.resize(baked_meshes.size())
	for m in baked_meshes:
		var p: String = out_dir.path_join("baked_%d.exr" % int(m["slice_index"]))
		textures[int(m["slice_index"])] = ResourceLoader.load(p, "", ResourceLoader.CACHE_MODE_IGNORE)

	# 6. build the LightmapGIData (Godot combines the slices into one layered atlas)
	var data := LightmapGIData.new()
	data.set_lightmap_textures(textures)
	data.set_uses_spherical_harmonics(false)
	var bounds := _world_aabb(targets)
	var sh := PackedColorArray()
	sh.resize(9)
	# one dummy probe point so set_capture_data applies real bounds (else the lightmap
	# instance gets an empty AABB and is culled — see RESEARCH.md pitfall 6).
	data.call("_set_probe_data", {
		"bounds": bounds,
		"points": PackedVector3Array([bounds.get_center()]),
		"sh": sh,
		"tetrahedra": PackedInt32Array(),
		"bsp": PackedInt32Array(),
		"interior": false,
		"baked_exposure": float(meta.get("baked_exposure", 1.0)),
		"lightprobe_hash": 0,
	})
	for m in baked_meshes:
		var t := _find(targets, m["name"])
		if t == null:
			push_warning("pavlaka: baked mesh '%s' not found in scene; skipped" % m["name"])
			continue
		var uv: Array = m["uv_scale"]
		data.add_user(t.path, Rect2(uv[0], uv[1], uv[2], uv[3]), int(m["slice_index"]), -1)

	# 7. save .lmbake and assign to the node
	var lmbake := out_dir.path_join("%s.lmbake" % root.name.to_snake_case())
	err = ResourceSaver.save(data, lmbake)
	if err != OK:
		push_error("pavlaka: saving .lmbake failed (%d)" % err)
		return err
	lm.light_data = data
	print("pavlaka: baked %d mesh(es) -> %s" % [data.get_user_count(), lmbake])
	return OK


static func _collect(node: Node, lm: LightmapGI, out: Array[Target]) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.gi_mode == GeometryInstance3D.GI_MODE_STATIC and _has_uv2(mi.mesh):
			var t := Target.new()
			t.node = mi
			t.path = lm.get_path_to(mi)
			t.name = mi.name
			out.append(t)
	for c in node.get_children():
		_collect(c, lm, out)


static func _has_uv2(mesh: Mesh) -> bool:
	# surface_get_arrays() works on every Mesh subclass (ArrayMesh + PrimitiveMesh);
	# surface_get_format() is ArrayMesh-only, so we check the arrays instead.
	if mesh == null:
		return false
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		if arrays.size() > Mesh.ARRAY_TEX_UV2:
			var uv2 = arrays[Mesh.ARRAY_TEX_UV2]
			if uv2 != null and uv2.size() > 0:
				return true
	return false


static func _world_aabb(targets: Array[Target]) -> AABB:
	var box := AABB()
	var first := true
	for t in targets:
		var local := t.node.mesh.get_aabb()
		var world := t.node.global_transform * local
		if first:
			box = world
			first = false
		else:
			box = box.merge(world)
	return box.grow(0.5)


static func _find(targets: Array[Target], mesh_name: String) -> Target:
	for t in targets:
		if t.name == mesh_name:
			return t
	return null


static func _write_exr_import(exr_res_path: String) -> void:
	var f := FileAccess.open(exr_res_path + ".import", FileAccess.WRITE)
	f.store_string("""[remap]

importer="2d_array_texture"
type="CompressedTexture2DArray"

[params]

compress/mode=2
compress/channel_pack=1
mipmaps/generate=false
slices/horizontal=1
slices/vertical=1
""")
	f.close()
