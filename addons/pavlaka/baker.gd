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

# Ordered bake steps. The optional `progress` callback is called with an index into this
# list as each step begins; the UI renders them as a checklist. Single source of truth so
# the labels and the reported indices can't drift apart.
const STEPS := ["Exporting scene", "Rendering in Blender", "Importing lightmaps", "Building LightmapGIData"]
const STEP_EXPORT := 0
const STEP_RENDER := 1
const STEP_IMPORT := 2
const STEP_BUILD := 3

const DEFAULTS := {
	"out_dir": "res://lightmaps/",
	"atlas": 512,
	"quality": 1, # LightmapGI BakeQuality: 0 Low, 1 Medium, 2 High, 3 Ultra
	"light_energy_scale": 1.0,
	"environment_mode": 1, # SCENE
	"environment_custom_sky": null,
	"environment_custom_color": Color(0.2, 0.2, 0.2),
	"environment_custom_energy": 1.0,
}


class Target:
	var node: MeshInstance3D
	var path: NodePath  # relative to the LightmapGI node
	var name: String


## Bake `lm`'s scene. Returns OK or an error code; messages go to the editor log.
## `progress` (optional) is called with the current step index (see STEPS) for UI feedback.
## `cancelled` (optional) is a single-element Array; set cancelled[0]=true to abort the
## bake — the running Blender process is killed and ERR_SKIP is returned.
static func bake(root: Node3D, lm: LightmapGI, blender_path: String, opts: Dictionary = {}, progress := Callable(), cancelled: Array = []) -> int:
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

	# 2. export the scene (geometry + lights) to a temp glb for Blender.
	# Build a fresh export tree (copied meshes + lights, in world space) instead of
	# duplicating the live scene: duplicate() chokes on CSG nodes ("child disappeared
	# while duplicating") which silently dropped lights. This also naturally excludes
	# hidden nodes (so no required KHR_node_visibility extension older Blenders reject).
	_report(progress, STEP_EXPORT)
	DirAccess.make_dir_recursive_absolute("user://pavlaka_tmp")
	var glb_abs := ProjectSettings.globalize_path("user://pavlaka_tmp/scene.glb")
	var export_root := _build_export_scene(root)
	var n_lights := 0
	for c in export_root.get_children():
		if c is Light3D:
			n_lights += 1
	if n_lights == 0:
		print("pavlaka: no Static lights found — baking ambient only. Set a light's Bake Mode to Static to include it in the bake.")
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_scene(export_root, state)
	if err == OK:
		err = doc.write_to_filesystem(state, glb_abs)
	export_root.free()
	if err != OK:
		push_error("pavlaka: glTF export failed (%d)" % err)
		return err

	# 3. run Blender headless to bake.
	# Per-scene output folder that mirrors the scene's path under the base dir, so two
	# scenes with the same name in different folders never collide.
	var out_dir := _scene_bake_dir(root, cfg["out_dir"])
	DirAccess.make_dir_recursive_absolute(out_dir)
	# write bake parameters (incl. each Static light's actual energy + linear color) to a
	# JSON the bake script reads, instead of a long positional arg list
	var lights: Array = []
	_collect_lights(root, lights)
	var env := _resolve_environment(root, cfg)
	var params := {
		"atlas": cfg["atlas"],
		"samples": _samples_for_quality(int(cfg["quality"])),
		"light_energy_scale": cfg["light_energy_scale"],
		"lights": lights,
		"sky_panorama": env["sky_panorama"],
		"ambient_color": env["ambient_color"],
		"ambient_energy": env["ambient_energy"],
	}
	var params_path := "user://pavlaka_tmp/params.json"
	var pf := FileAccess.open(params_path, FileAccess.WRITE)
	pf.store_string(JSON.stringify(params))
	pf.close()
	var args := PackedStringArray([
		"--background", "--python", ProjectSettings.globalize_path(BAKE_SCRIPT), "--",
		glb_abs, ProjectSettings.globalize_path(out_dir), ProjectSettings.globalize_path(params_path),
	])
	# Run Blender non-blocking and poll, so the editor stays responsive (and we can show
	# progress) instead of freezing. Output is captured via bake.log (create_process
	# can't read stdout). Wait one frame between polls to yield to the editor.
	print("pavlaka: running Blender...")
	var pid := OS.create_process(blender_path, args)
	if pid <= 0:
		push_error("pavlaka: failed to launch Blender at '%s'" % blender_path)
		return ERR_CANT_CREATE
	_report(progress, STEP_RENDER)
	while OS.is_process_running(pid):
		if not cancelled.is_empty() and cancelled[0]:
			OS.kill(pid)
			print("pavlaka: bake cancelled")
			return ERR_SKIP
		await Engine.get_main_loop().process_frame
	# surface Blender's log for diagnostics (it mirrors everything bake.py printed)
	var log_txt := FileAccess.get_file_as_string(out_dir.path_join("bake.log"))
	if not log_txt.is_empty():
		print("pavlaka: --- Blender log ---\n%s\npavlaka: --- end ---" % log_txt)

	# 4. read bake metadata
	_report(progress, STEP_IMPORT)
	var meta_path := out_dir.path_join("baked.json")
	var meta_str := FileAccess.get_file_as_string(meta_path)
	if meta_str.is_empty():
		push_error("pavlaka: missing bake metadata at %s — Blender exited 0 but wrote no result (see output above)" % meta_path)
		return ERR_FILE_CANT_READ
	var meta: Dictionary = JSON.parse_string(meta_str)
	var baked_meshes: Array = meta.get("meshes", [])
	var bake_errors: Array = meta.get("errors", [])
	if baked_meshes.is_empty():
		push_error("pavlaka: Blender bake produced no lightmaps (see bake.log). Errors: %s"
			% ("; ".join(PackedStringArray(bake_errors)) if not bake_errors.is_empty() else "none reported"))
		return FAILED

	# 5. import the per-mesh EXR slices as CompressedTexture2DArray.
	# Prefer the light path (update_file + reimport_files): it (re)imports only these
	# files and, crucially, does NOT trigger a project-wide script-class rescan — so it
	# won't reload addon scripts mid-bake and kill this coroutine. A full scan() is only
	# needed for brand-new files the EditorFileSystem doesn't know yet (e.g. after the
	# output folder was deleted), so fall back to it only if the light path can't load.
	var efs := EditorInterface.get_resource_filesystem()
	var slice_paths := PackedStringArray()
	var any_new := false
	for m in baked_meshes:
		var p: String = out_dir.path_join(m["file"])
		if _write_exr_import(p): # true when a fresh .import was created (file is new)
			any_new = true
		efs.update_file(p)
		slice_paths.append(p)

	var textures: Array = []
	if not any_new:
		# warm re-bake: files are already known/imported, so refresh them cheaply
		# (no project-wide script rescan, and no "can't find file" on unknown files)
		efs.reimport_files(slice_paths)
		textures = _load_slices(baked_meshes, out_dir)
	if textures.is_empty():
		# cold case: files unknown to the EditorFileSystem — full scan + wait, then retry
		var scanned := [false]
		var on_changed := func(): scanned[0] = true
		efs.filesystem_changed.connect(on_changed)
		efs.scan()
		var frames := 0
		while not scanned[0] and frames < 1800:
			await Engine.get_main_loop().process_frame
			frames += 1
		if efs.filesystem_changed.is_connected(on_changed):
			efs.filesystem_changed.disconnect(on_changed)
		textures = _load_slices(baked_meshes, out_dir)
		if textures.is_empty():
			push_error("pavlaka: failed to import baked lightmap slices (see Output)")
			return ERR_FILE_CANT_READ

	# 6. build the LightmapGIData (Godot combines the slices into one layered atlas)
	_report(progress, STEP_BUILD)
	var data := LightmapGIData.new()
	data.set_lightmap_textures(textures)
	data.set_uses_spherical_harmonics(false)
	var bounds := _world_aabb(targets)
	# Keep probe points EMPTY so no probe gizmo is drawn. set_capture_data then forces the
	# RenderingServer bounds to empty, so we re-apply real bounds directly below (and the
	# LightmapBlenderGI re-applies them on load) — otherwise the instance is culled.
	data.call("_set_probe_data", {
		"bounds": bounds,
		"points": PackedVector3Array(),
		"sh": PackedColorArray(),
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

	# 7. save .lmbake (named after the scene, i.e. the output folder's leaf) and assign
	var lmbake := out_dir.path_join("%s.lmbake" % out_dir.get_file())
	err = ResourceSaver.save(data, lmbake)
	if err != OK:
		push_error("pavlaka: saving .lmbake failed (%d)" % err)
		return err
	lm.light_data = data
	# Apply the real bounds to the RenderingServer now (this session) and store them on
	# the node so they're re-applied on load — without any probe point (hence no gizmo).
	RenderingServer.lightmap_set_probe_bounds(data.get_rid(), bounds)
	if lm is LightmapBlenderGI:
		(lm as LightmapBlenderGI).baked_bounds = bounds
	print("pavlaka: baked %d mesh(es) -> %s" % [data.get_user_count(), lmbake])
	return OK


static func _collect(node: Node, lm: LightmapGI, out: Array[Target]) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		# hidden meshes don't bake (and are pruned from the export); skip them as targets
		if mi.visible and mi.gi_mode == GeometryInstance3D.GI_MODE_STATIC and _has_uv2(mi.mesh):
			var t := Target.new()
			t.node = mi
			t.path = lm.get_path_to(mi)
			t.name = mi.name
			out.append(t)
	for c in node.get_children():
		_collect(c, lm, out)


# Build a flat export scene of copied visible meshes + lights (in world space). Avoids
# duplicating the live tree (CSG nodes break duplicate()), and only includes what the
# bake needs. All meshes occlude/bounce; bake.py bakes the ones that carry a UV2.
static func _build_export_scene(root: Node) -> Node3D:
	var export_root := Node3D.new()
	export_root.name = root.name
	_gather_into(root, export_root)
	return export_root


# Resolve the Environment mode into bake params: either a sky panorama path, or a flat
# ambient color+energy. Mirrors LightmapGI's Environment Mode.
static func _resolve_environment(root: Node, cfg: Dictionary) -> Dictionary:
	var none := {"sky_panorama": "", "ambient_color": [0.0, 0.0, 0.0], "ambient_energy": 0.0}
	match int(cfg["environment_mode"]):
		1: # SCENE — bake the scene's WorldEnvironment (sky or background)
			var e := _find_environment(root)
			if e != null:
				var p := _bake_env_panorama(e)
				if p != "":
					return {"sky_panorama": p, "ambient_color": [0.0, 0.0, 0.0], "ambient_energy": 0.0}
			return none
		2: # CUSTOM_SKY — bake the given Sky resource
			var sky: Sky = cfg["environment_custom_sky"]
			if sky != null:
				var p := _bake_sky_resource(sky, float(cfg["environment_custom_energy"]))
				if p != "":
					return {"sky_panorama": p, "ambient_color": [0.0, 0.0, 0.0], "ambient_energy": 0.0}
			return none
		3: # CUSTOM_COLOR — flat ambient
			var lin: Color = (cfg["environment_custom_color"] as Color).srgb_to_linear()
			return {"sky_panorama": "", "ambient_color": [lin.r, lin.g, lin.b], "ambient_energy": float(cfg["environment_custom_energy"])}
	return none # DISABLED


static func _bake_env_panorama(env: Environment) -> String:
	var img := RenderingServer.environment_bake_panorama(env.get_rid(), false, Vector2i(256, 128))
	return _save_panorama(img)


static func _bake_sky_resource(sky: Sky, energy: float) -> String:
	var img := RenderingServer.sky_bake_panorama(sky.get_rid(), energy, false, Vector2i(256, 128))
	return _save_panorama(img)


static func _save_panorama(img: Image) -> String:
	if img == null or img.is_empty():
		return ""
	var rel := "user://pavlaka_tmp/sky.exr"
	if img.save_exr(rel) != OK:
		push_warning("pavlaka: failed to save sky panorama; using no ambient")
		return ""
	return ProjectSettings.globalize_path(rel)


static func _find_environment(node: Node) -> Environment:
	if node is WorldEnvironment and (node as WorldEnvironment).environment != null:
		return (node as WorldEnvironment).environment
	for c in node.get_children():
		var e := _find_environment(c)
		if e != null:
			return e
	return null


# collect Static, visible lights' actual energy + linear color (matched by node name in
# bake.py) so the bake uses real per-light values instead of a fixed energy
static func _collect_lights(node: Node, out: Array) -> void:
	for c in node.get_children():
		if c is Light3D and (c as Light3D).is_visible_in_tree() and (c as Light3D).light_bake_mode == Light3D.BAKE_STATIC:
			var l := c as Light3D
			var lin := l.light_color.srgb_to_linear()
			out.append({"name": l.name, "energy": l.light_energy, "color": [lin.r, lin.g, lin.b]})
		_collect_lights(c, out)


static func _gather_into(node: Node, export_root: Node3D) -> void:
	for c in node.get_children():
		if c is MeshInstance3D and (c as MeshInstance3D).is_visible_in_tree() and (c as MeshInstance3D).mesh != null:
			var mi := c as MeshInstance3D
			var copy := MeshInstance3D.new()
			copy.name = mi.name
			copy.mesh = mi.mesh
			copy.transform = mi.global_transform
			export_root.add_child(copy)
			copy.owner = export_root
		elif c is Light3D and (c as Light3D).is_visible_in_tree() and (c as Light3D).light_bake_mode == Light3D.BAKE_STATIC:
			var lcopy: Light3D = (c as Light3D).duplicate()
			lcopy.transform = (c as Light3D).global_transform
			export_root.add_child(lcopy)
			lcopy.owner = export_root
		_gather_into(c, export_root)


static func _report(progress: Callable, step: int) -> void:
	if progress.is_valid():
		progress.call(step)


# map LightmapGI BakeQuality (Low/Medium/High/Ultra) to Cycles samples (denoise cleans up)
static func _samples_for_quality(q: int) -> int:
	match q:
		0: return 64    # Low
		2: return 256   # High
		3: return 512   # Ultra
	return 128          # Medium (default)


# Per-scene output folder under `base`, mirroring the scene's res:// path so same-named
# scenes in different folders don't collide (e.g. res://a/level.tscn -> base/a/level).
static func _scene_bake_dir(root: Node, base: String) -> String:
	var scene_path := root.scene_file_path
	if scene_path.is_empty():
		push_warning("pavlaka: scene not saved — baking into a folder named after the root node; save the scene for stable, collision-free paths")
		return base.path_join(String(root.name).validate_filename())
	return base.path_join(scene_path.trim_prefix("res://").get_basename())


# Load all per-mesh slices (fresh from disk) into a slice-indexed array. Returns []
# if any slice isn't importable yet, so the caller can fall back to a full scan.
static func _load_slices(baked_meshes: Array, out_dir: String) -> Array:
	var textures: Array = []
	textures.resize(baked_meshes.size())
	for m in baked_meshes:
		var p: String = out_dir.path_join(m["file"])
		var tex := ResourceLoader.load(p, "", ResourceLoader.CACHE_MODE_IGNORE)
		if tex == null:
			return []
		textures[int(m["slice_index"])] = tex
	return textures


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


# Returns true if a fresh .import was created (the file is new to the project), false if
# one already existed (a re-bake). Keeps an existing .import as-is so its assigned UID
# stays stable across re-bakes (else scenes/.lmbake referencing the old UID warn).
static func _write_exr_import(exr_res_path: String) -> bool:
	if FileAccess.file_exists(exr_res_path + ".import"):
		return false
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
	return true
