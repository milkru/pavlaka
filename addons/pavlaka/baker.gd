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
## `cancelled` (optional) is a single-element Array; set cancelled[0]=true to abort the
## bake — the running Blender process is killed and ERR_SKIP is returned.
static func bake(root: Node3D, lm: LightmapGI, blender_path: String, opts: Dictionary = {}, cancelled: Array = []) -> int:
	var cfg := DEFAULTS.duplicate()
	for k in opts:
		cfg[k] = opts[k]

	if blender_path.is_empty() or not FileAccess.file_exists(blender_path):
		push_error("pavlaka: Blender executable not found: '%s'" % blender_path)
		return ERR_FILE_NOT_FOUND

	var bake_start := Time.get_ticks_msec()

	# 1. collect static meshes that carry a UV2 (the lightmap UV Godot owns)
	var targets: Array[Target] = []
	_collect(root, lm, targets)
	if targets.is_empty():
		push_error("pavlaka: no static MeshInstance3D with UV2 found under '%s'" % root.name)
		return ERR_INVALID_DATA
	print("pavlaka: %d lightmap target(s): %s" % [targets.size(),
		targets.map(func(t): return t.name)])

	# 2. pack the atlas: each mesh gets a chunk of the single lightmap sized by its
	# world-space surface area; the packed sheet is scaled to lightmap_size (see
	# _pack_atlas). Done before baking so each mesh can be baked at its exact chunk size.
	var pack := _pack_atlas(targets, int(cfg["lightmap_size"]))
	if pack.is_empty():
		push_error("pavlaka: targets have zero surface area; nothing to bake")
		return ERR_INVALID_DATA
	var atlas_dim: Vector2i = pack["atlas"]
	var rects: Array = pack["rects"] # Array[Rect2i], aligned with `targets`
	var rect_by_name := {}
	var size_by_name := {}
	for i in targets.size():
		rect_by_name[targets[i].name] = rects[i]
		size_by_name[targets[i].name] = (rects[i] as Rect2i).size.x # chunks are square

	# 3. export the scene (geometry + lights) to a temp glb for Blender.
	# Build a fresh export tree (copied meshes + lights, in world space) instead of
	# duplicating the live scene: duplicate() chokes on CSG nodes ("child disappeared
	# while duplicating") which silently dropped lights. This also naturally excludes
	# hidden nodes (so no required KHR_node_visibility extension older Blenders reject).
	var work := "user://pavlaka_tmp"
	DirAccess.make_dir_recursive_absolute(work)
	var work_abs := ProjectSettings.globalize_path(work)
	var glb_abs := work_abs.path_join("scene.glb")
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

	# 4. run Blender headless: bake each mesh into its own EXR at its chunk size.
	# Intermediates (per-mesh EXRs + baked.json + bake.log) go to the temp work dir; the
	# final packed atlas + .lmbake go to the per-scene output folder (mirrors the scene's
	# path under the base dir, so same-named scenes in different folders never collide).
	var out_dir := _scene_bake_dir(root, cfg["out_dir"])
	DirAccess.make_dir_recursive_absolute(out_dir)
	var lights: Array = []
	_collect_lights(root, lights)
	var env := _resolve_environment(root, cfg)
	var params := {
		"sizes": size_by_name, # per-mesh square chunk size in px
		"samples": _samples_for_quality(int(cfg["quality"])),
		"light_energy_scale": cfg["light_energy_scale"],
		"lights": lights,
		"sky_panorama": env["sky_panorama"],
		"ambient_color": env["ambient_color"],
		"ambient_energy": env["ambient_energy"],
	}
	var params_path := work + "/params.json"
	var pf := FileAccess.open(params_path, FileAccess.WRITE)
	pf.store_string(JSON.stringify(params))
	pf.close()
	var args := PackedStringArray([
		"--background", "--python", ProjectSettings.globalize_path(BAKE_SCRIPT), "--",
		glb_abs, work_abs, ProjectSettings.globalize_path(params_path),
	])
	# Run Blender non-blocking and poll, so the editor stays responsive instead of freezing.
	# Output is captured via bake.log (create_process can't read stdout); yield each frame.
	print("pavlaka: running Blender...")
	var pid := OS.create_process(blender_path, args)
	if pid <= 0:
		push_error("pavlaka: failed to launch Blender at '%s'" % blender_path)
		return ERR_CANT_CREATE
	while OS.is_process_running(pid):
		if not cancelled.is_empty() and cancelled[0]:
			OS.kill(pid)
			print("pavlaka: bake cancelled")
			return ERR_SKIP
		await Engine.get_main_loop().process_frame

	# 5. read bake metadata from the work dir. Blender's full log is kept in bake.log; we
	# only echo it to the Godot console when something actually went wrong.
	var meta_str := FileAccess.get_file_as_string(work + "/baked.json")
	if meta_str.is_empty():
		_dump_blender_log(work_abs)
		push_error("pavlaka: Blender exited 0 but wrote no result (see Blender log above)")
		return ERR_FILE_CANT_READ
	var meta: Dictionary = JSON.parse_string(meta_str)
	var baked_meshes: Array = meta.get("meshes", [])
	var bake_errors: Array = meta.get("errors", [])
	if baked_meshes.is_empty():
		_dump_blender_log(work_abs)
		push_error("pavlaka: Blender bake produced no lightmaps (see Blender log above). Errors: %s"
			% ("; ".join(PackedStringArray(bake_errors)) if not bake_errors.is_empty() else "none reported"))
		return FAILED
	if not bake_errors.is_empty():
		push_warning("pavlaka: Blender reported %d bake error(s); see bake.log in %s" % [bake_errors.size(), work_abs])

	# 6. composite the per-mesh EXRs into one packed atlas (HDR/linear), blitting each into
	# its chunk. A gutter was reserved during packing so neighbours can't bleed.
	var atlas_img := Image.create(atlas_dim.x, atlas_dim.y, false, Image.FORMAT_RGBAF)
	for m in baked_meshes:
		var nm: String = m["name"]
		if not rect_by_name.has(nm):
			push_warning("pavlaka: baked mesh '%s' not in packing; skipped" % nm)
			continue
		var slice := Image.load_from_file(work_abs.path_join(m["file"]))
		if slice == null:
			push_error("pavlaka: failed to read baked slice %s" % m["file"])
			return ERR_FILE_CANT_READ
		slice.convert(Image.FORMAT_RGBAF)
		var r: Rect2i = rect_by_name[nm]
		atlas_img.blit_rect(slice, Rect2i(Vector2i.ZERO, slice.get_size()), r.position)

	# 7. save the atlas as the single lightmap texture in the output folder and import it
	var atlas_path := out_dir.path_join("%s.exr" % out_dir.get_file())
	if atlas_img.save_exr(atlas_path) != OK:
		push_error("pavlaka: failed to save lightmap atlas to %s" % atlas_path)
		return ERR_CANT_CREATE
	# Prefer the light import path (update_file + reimport_files): it won't trigger a
	# project-wide script-class rescan that would reload addon scripts mid-bake. Fall back to
	# a full scan only for a brand-new file the EditorFileSystem doesn't know yet.
	var efs := EditorInterface.get_resource_filesystem()
	var fresh := _write_exr_import(atlas_path) # true when a new .import was created
	efs.update_file(atlas_path)
	var atlas_tex: Texture = null
	if not fresh:
		efs.reimport_files(PackedStringArray([atlas_path]))
		atlas_tex = ResourceLoader.load(atlas_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if atlas_tex == null:
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
		atlas_tex = ResourceLoader.load(atlas_path, "", ResourceLoader.CACHE_MODE_IGNORE)
		if atlas_tex == null:
			push_error("pavlaka: failed to import baked lightmap atlas (see Output)")
			return ERR_FILE_CANT_READ

	# 8. build the LightmapGIData: one atlas texture, each mesh mapped to its sub-rect via
	# add_user's uv_scale (remaps the mesh's [0,1] UV2 into its chunk of the atlas).
	var data := LightmapGIData.new()
	data.set_lightmap_textures([atlas_tex])
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
	var aw := float(atlas_dim.x)
	var ah := float(atlas_dim.y)
	for m in baked_meshes:
		var nm: String = m["name"]
		var t := _find(targets, nm)
		if t == null or not rect_by_name.has(nm):
			continue
		var r: Rect2i = rect_by_name[nm]
		data.add_user(t.path,
			Rect2(r.position.x / aw, r.position.y / ah, r.size.x / aw, r.size.y / ah), 0, -1)

	# 9. save .lmbake (named after the scene, i.e. the output folder's leaf) and assign
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
	var secs := (Time.get_ticks_msec() - bake_start) / 1000
	var took := ("%d m %d s" % [secs / 60, secs % 60]) if secs >= 60 else ("%d s" % secs)
	print("pavlaka: baked %d mesh(es) into a %dx%d atlas in %s -> %s"
		% [data.get_user_count(), atlas_dim.x, atlas_dim.y, took, lmbake])
	return OK


static func _dump_blender_log(out_dir: String) -> void:
	var log_txt := FileAccess.get_file_as_string(out_dir.path_join("bake.log"))
	if not log_txt.is_empty():
		print("pavlaka: --- Blender log ---\n%s\npavlaka: --- end ---" % log_txt)


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


# px gutter kept between packed meshes so neighbours can't bleed into each other
const ATLAS_GUTTER := 4


# World-space surface area of a mesh instance (triangle areas in world space, so a scaled
# or larger object occupies proportionally more of the atlas).
static func _world_surface_area(mi: MeshInstance3D) -> float:
	var mesh := mi.mesh
	if mesh == null:
		return 0.0
	var xform := mi.global_transform
	var area := 0.0
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		if idx.size() >= 3:
			for i in range(0, idx.size() - 2, 3):
				area += 0.5 * (xform * verts[idx[i + 1]] - xform * verts[idx[i]]).cross(
					xform * verts[idx[i + 2]] - xform * verts[idx[i]]).length()
		elif verts.size() >= 3: # non-indexed triangles
			for i in range(0, verts.size() - 2, 3):
				area += 0.5 * (xform * verts[i + 1] - xform * verts[i]).cross(
					xform * verts[i + 2] - xform * verts[i]).length()
	return area


# Pack the targets into one atlas: each mesh gets a square chunk sized by its world surface
# area, chunks are bin-packed (Geometry2D.make_atlas) with a gutter, then the whole sheet is
# scaled so its longest side == lightmap_size (aspect preserved). Returns
# { "atlas": Vector2i, "rects": Array[Rect2i] } (rects aligned with `targets`), or {} if the
# total area is zero.
static func _pack_atlas(targets: Array[Target], lightmap_size: int) -> Dictionary:
	var areas: Array[float] = []
	var total := 0.0
	for t in targets:
		var a := _world_surface_area(t.node)
		areas.append(a)
		total += a
	if total <= 0.0:
		return {}
	# scale so the square chunks' combined area ≈ lightmap_size² before packing waste
	var k := float(lightmap_size) / sqrt(total)
	var content: Array[float] = [] # content side (px) per mesh, before the final fit-scale
	var sizes := PackedVector2Array()
	for a in areas:
		var side: float = max(8.0, sqrt(a) * k) # floor so tiny meshes still get some texels
		content.append(side)
		sizes.append(Vector2(side + ATLAS_GUTTER, side + ATLAS_GUTTER))
	var packed := Geometry2D.make_atlas(sizes)
	var points: PackedVector2Array = packed["points"]
	var psize: Vector2i = packed["size"]
	# scale the packed sheet so its longest side is exactly lightmap_size
	var fit := float(lightmap_size) / float(maxi(psize.x, psize.y))
	var atlas := Vector2i(roundi(psize.x * fit), roundi(psize.y * fit))
	var rects: Array[Rect2i] = []
	for i in targets.size():
		# centre the content in its gutter-padded cell, then apply the fit-scale
		var pos := (points[i] + Vector2(ATLAS_GUTTER, ATLAS_GUTTER) * 0.5) * fit
		var sz: float = content[i] * fit
		rects.append(Rect2i(
			Vector2i(roundi(pos.x), roundi(pos.y)),
			Vector2i(maxi(1, roundi(sz)), maxi(1, roundi(sz)))))
	return {"atlas": atlas, "rects": rects}


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
