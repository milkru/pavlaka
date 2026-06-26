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

# texels per world unit at texel_scale = 1.0 — chunk side px = sqrt(area) * this * texel_scale
const BASE_DENSITY := 10.0

const DEFAULTS := {
	"max_texture_size": 16384, # LightmapGI's own cap on each atlas page's dimensions
	"texel_scale": 1.0, # LightmapGI's density multiplier (higher = sharper / more texels)
	"compress": false, # VRAM-compress pages (smaller, POT-rounded) vs lossless exact-fit
	"use_gpu": true,   # render the bake on GPU if available, else CPU
	"bounces": 3,      # Cycles diffuse bounces (indirect GI)
	"bake_margin": 16, # px the bake is dilated past each UV island edge
	"indirect_clamp": 0.0, # Cycles indirect sample clamp (0 = off); kills fireflies
	"denoise": true,   # OIDN denoise each page
	"quality": 1, # LightmapGI BakeQuality: 0 Low, 1 Medium, 2 High, 3 Ultra
	"environment_mode": 1, # SCENE
	"environment_custom_sky": null,
	"environment_custom_color": Color(0.2, 0.2, 0.2),
	"environment_custom_energy": 1.0,
}


class Target:
	var node: MeshInstance3D
	var path: NodePath  # relative to the LightmapGI node
	var name: String    # the node's name (may collide with other nodes — display only)
	var key: String     # unique per-target id; used as the export/bake/atlas identifier


## Bake `lm`'s scene. Returns OK or an error code; messages go to the editor log.
## `save_path` is the .lmbake file to write (the page EXRs go beside it, named after it).
## `cancelled` (optional) is a single-element Array; set cancelled[0]=true to abort the
## bake — the running Blender process is killed and ERR_SKIP is returned.
static func bake(root: Node3D, lm: LightmapGI, blender_path: String, save_path: String, opts: Dictionary = {}, cancelled: Array = []) -> int:
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

	# 2. pack the atlas pages: each mesh gets a square chunk sized by its world-space surface
	# area at the chosen texel density, shelf-packed into pages that grow to fit but never
	# exceed max_texture_size (see _pack_pages). Done before baking so each mesh can be baked
	# at its exact chunk size.
	var max_tex := int(cfg["max_texture_size"])
	var pack := _pack_pages(targets, max_tex, float(cfg["texel_scale"]))
	var page_dims: Array = pack["page_dims"] # Vector2i per page
	var n_pages: int = page_dims.size()
	var placements: Array = pack["placements"] # {page, rect}, aligned with `targets`
	if n_pages == 0:
		push_error("pavlaka: targets have zero surface area; nothing to bake")
		return ERR_INVALID_DATA
	for nm in pack["fallbacks"]:
		push_warning(("pavlaka: mesh '%s' is too large to fit a %dpx page at texel_scale %.3f; "
			+ "its lightmap was shrunk to fit (lower density there). Split the mesh, raise "
			+ "Max Texture Size, or lower texel_scale.") % [nm, max_tex, float(cfg["texel_scale"])])
	if n_pages > 8:
		push_warning("pavlaka: bake uses %d atlas pages — lower texel_scale for fewer pages if VRAM is a concern" % n_pages)
	# key everything by each target's unique key (not its node name, which can collide when
	# meshes are duplicated) so the bake result maps back to the right chunk/target.
	var place_by_key := {}
	var size_by_key := {}
	var target_by_key := {}
	for i in targets.size():
		var k: String = targets[i].key
		place_by_key[k] = placements[i]
		size_by_key[k] = (placements[i]["rect"] as Rect2i).size.x # chunks are square
		target_by_key[k] = targets[i]

	# 3. export the scene (geometry + lights) to a temp glb for Blender.
	# Build a fresh export tree (copied meshes + lights, in world space) instead of
	# duplicating the live scene: duplicate() chokes on CSG nodes ("child disappeared
	# while duplicating") which silently dropped lights. This also naturally excludes
	# hidden nodes (so no required KHR_node_visibility extension older Blenders reject).
	var work := "user://pavlaka_tmp"
	DirAccess.make_dir_recursive_absolute(work)
	var work_abs := ProjectSettings.globalize_path(work)
	var glb_abs := work_abs.path_join("scene.glb")
	var export_root := _build_export_scene(root, targets)
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
	# final pages + .lmbake go beside the chosen save_path, named after it.
	var out_dir := save_path.get_base_dir()
	var base_name := save_path.get_file().get_basename()
	# if the output folder is brand new, the EditorFileSystem doesn't know it yet, so we must
	# scan (not reimport_files) to import the pages — tracked below to pick the right path.
	var dir_was_new := not DirAccess.dir_exists_absolute(out_dir)
	DirAccess.make_dir_recursive_absolute(out_dir)
	var lights: Array = []
	_collect_lights(root, lights)
	var env := _resolve_environment(root, cfg)
	var params := {
		"sizes": size_by_key, # per-mesh square chunk size in px, keyed by unique export name
		"samples": _samples_for_quality(int(cfg["quality"])),
		"use_gpu": cfg["use_gpu"],
		"bounces": cfg["bounces"],
		"bake_margin": cfg["bake_margin"],
		"indirect_clamp": cfg["indirect_clamp"],
		"denoise": cfg["denoise"],
		"lights": lights,
		"sky_panorama": env["sky_panorama"],
		"sky_rotation": env.get("sky_rotation", [0.0, 0.0, 0.0]),
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
	# Prepare the atlas page images + bounds up front so finished meshes can be streamed into a
	# live preview while Blender is still baking the rest.
	var page_imgs: Array = []
	for i in n_pages:
		var d: Vector2i = page_dims[i]
		page_imgs.append(Image.create(d.x, d.y, false, Image.FORMAT_RGBAF))
	var bounds := _world_aabb(targets)
	var composited := {} # mesh name -> true (already blitted into page_imgs)
	var orig_data: LightmapGIData = lm.light_data # restored if the bake is cancelled
	_clear_markers(work_abs) # drop any .done markers left by a previous bake in this temp dir

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
			lm.light_data = orig_data # undo any live-preview assignment
			print("pavlaka: bake cancelled")
			return ERR_SKIP
		# stream each finished mesh into the live preview the moment its marker appears
		var streamed := false
		for done in _read_done_markers(work_abs, composited):
			var k: String = done["name"] # bake.py names objects by the unique key
			if _blit_mesh(page_imgs, place_by_key, work_abs, k, done["file"]):
				composited[k] = true
				streamed = true
				var disp: String = target_by_key[k].name if target_by_key.has(k) else k
				print("pavlaka: baked %d/%d  %s" % [composited.size(), targets.size(), disp])
		if streamed:
			var prev := _make_data(_preview_texes(page_imgs), place_by_key, page_dims,
				composited.keys(), target_by_key, bounds, 1.0)
			_assign_data(lm, prev, bounds)
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

	# 6. finish compositing: most meshes were streamed into page_imgs during the bake; blit any
	# that weren't yet (the last marker can arrive right at exit, or a marker could be missed).
	for m in baked_meshes:
		var k: String = m["name"] # the unique key bake.py named the object by
		if composited.has(k):
			continue
		if not place_by_key.has(k):
			push_warning("pavlaka: baked mesh '%s' not in packing; skipped" % k)
			continue
		if not _blit_mesh(page_imgs, place_by_key, work_abs, k, m["file"]):
			push_error("pavlaka: failed to read baked slice %s" % m["file"])
			return ERR_FILE_CANT_READ
		composited[k] = true
		var disp: String = target_by_key[k].name if target_by_key.has(k) else k
		print("pavlaka: baked %d/%d  %s" % [composited.size(), targets.size(), disp])

	# 7. save each page and import it as a CompressedTexture2DArray (one per page).
	# Prefer the light import path (update_file + reimport_files): it won't trigger a
	# project-wide script-class rescan that would reload addon scripts mid-bake. Fall back to
	# a full scan only for brand-new files the EditorFileSystem doesn't know yet.
	var efs := EditorInterface.get_resource_filesystem()
	var page_paths := PackedStringArray()
	for i in n_pages:
		var pp := out_dir.path_join("%s_%d.exr" % [base_name, i])
		if (page_imgs[i] as Image).save_exr(pp) != OK:
			push_error("pavlaka: failed to save lightmap page %s" % pp)
			return ERR_CANT_CREATE
		_write_exr_import(pp, bool(cfg["compress"]))
		efs.update_file(pp)
		page_paths.append(pp)
	var page_texes: Array = []
	# In an already-tracked folder, update_file + reimport_files imports the pages
	# synchronously — reliable whether new or re-baked (and, unlike a scan, it works even when
	# another lightmap already exists in the folder). A brand-new folder isn't known to the
	# EditorFileSystem yet, so reimport_files would error there; scan instead (below).
	if not dir_was_new:
		efs.reimport_files(page_paths)
		page_texes = _load_pages(page_paths)
	if page_texes.is_empty():
		# brand-new (or still-unknown) folder: rescan so the EditorFileSystem discovers and
		# imports the pages, then load.
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
		page_texes = _load_pages(page_paths)
		if page_texes.is_empty():
			push_error("pavlaka: failed to import baked lightmap pages (see Output)")
			return ERR_FILE_CANT_READ

	# 8. build the final LightmapGIData from the imported pages (replaces the live preview).
	var final_keys: Array = baked_meshes.map(func(m): return m["name"])
	var data := _make_data(page_texes, place_by_key, page_dims, final_keys, target_by_key, bounds,
		float(meta.get("baked_exposure", 1.0)))

	# 9. save .lmbake (to the chosen save_path) and assign
	var lmbake := save_path
	err = ResourceSaver.save(data, lmbake)
	if err != OK:
		push_error("pavlaka: saving .lmbake failed (%d)" % err)
		return err
	# Link the in-memory resource to the saved file so the scene references the .lmbake
	# externally (like native LightmapGI) instead of embedding the whole LightmapGIData inline.
	data.take_over_path(lmbake)
	efs.update_file(lmbake) # let the editor track the new .lmbake file
	_assign_data(lm, data, bounds) # replaces the live preview with the final imported result
	# drop pages left by a denser previous bake. Done last, after the new pages are imported —
	# deleting tracked files mid-import corrupts the EditorFileSystem scan and they fail.
	_cleanup_stale_pages(out_dir, base_name, n_pages)
	var secs := (Time.get_ticks_msec() - bake_start) / 1000
	var took := ("%d m %d s" % [secs / 60, secs % 60]) if secs >= 60 else ("%d s" % secs)
	var dims_str := ", ".join((page_dims as Array).map(func(d): return "%dx%d" % [d.x, d.y]))
	print("pavlaka: baked %d mesh(es) into %d page(s) [%s] in %s -> %s"
		% [data.get_user_count(), n_pages, dims_str, took, lmbake])
	return OK


# Build a LightmapGIData from page textures + per-mesh placements. Shared by the live preview
# (in-memory textures, the meshes baked so far) and the final result (imported textures, all
# meshes). Empty probe points -> no probe gizmo; real bounds are applied via the RenderingServer.
static func _make_data(textures: Array, place_by_key: Dictionary, page_dims: Array,
		keys: Array, target_by_key: Dictionary, bounds: AABB, exposure: float) -> LightmapGIData:
	var data := LightmapGIData.new()
	data.set_lightmap_textures(textures)
	data.set_uses_spherical_harmonics(false)
	data.call("_set_probe_data", {
		"bounds": bounds, "points": PackedVector3Array(), "sh": PackedColorArray(),
		"tetrahedra": PackedInt32Array(), "bsp": PackedInt32Array(), "interior": false,
		"baked_exposure": exposure, "lightprobe_hash": 0,
	})
	for k in keys:
		if not target_by_key.has(k) or not place_by_key.has(k):
			continue
		var t: Target = target_by_key[k]
		var pl: Dictionary = place_by_key[k]
		var r: Rect2i = pl["rect"]
		# normalize the chunk rect by its own page's dimensions (pages can differ in size)
		var d: Vector2i = page_dims[pl["page"]]
		data.add_user(t.path, Rect2(float(r.position.x) / d.x, float(r.position.y) / d.y,
			float(r.size.x) / d.x, float(r.size.y) / d.y), int(pl["page"]), -1)
	return data


# Assign a LightmapGIData to the node and re-apply real bounds (no probe point -> no gizmo).
static func _assign_data(lm: LightmapGI, data: LightmapGIData, bounds: AABB) -> void:
	lm.light_data = data
	RenderingServer.lightmap_set_probe_bounds(data.get_rid(), bounds)
	if lm is BlenderLightmapGI:
		(lm as BlenderLightmapGI).baked_bounds = bounds


# In-memory Texture2DArray per page (one layer each), for the live preview without importing
# (avoids the editor-filesystem reimport path mid-bake).
static func _preview_texes(page_imgs: Array) -> Array:
	var texes: Array = []
	for img in page_imgs:
		var t := Texture2DArray.new()
		t.create_from_images([img])
		texes.append(t)
	return texes


# Blit one baked mesh's EXR into its atlas page. Returns false if the file can't be read.
static func _blit_mesh(page_imgs: Array, place_by_key: Dictionary, work_abs: String,
		key: String, file_name: String) -> bool:
	if not place_by_key.has(key):
		return false
	var slice := Image.load_from_file(work_abs.path_join(file_name))
	if slice == null:
		return false
	slice.convert(Image.FORMAT_RGBAF)
	var pl: Dictionary = place_by_key[key]
	var r: Rect2i = pl["rect"]
	(page_imgs[pl["page"]] as Image).blit_rect(slice, Rect2i(Vector2i.ZERO, slice.get_size()), r.position)
	return true


# Read .done markers (written by bake.py after each mesh) whose mesh isn't composited yet.
static func _read_done_markers(work_abs: String, composited: Dictionary) -> Array:
	var out: Array = []
	var dir := DirAccess.open(work_abs)
	if dir == null:
		return out
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if f.ends_with(".done"):
			var j = JSON.parse_string(FileAccess.get_file_as_string(work_abs.path_join(f)))
			if j is Dictionary and j.has("name") and j.has("file") and not composited.has(j["name"]):
				out.append(j)
		f = dir.get_next()
	dir.list_dir_end()
	return out


# Delete .done markers left in the temp dir by a previous bake, so they aren't read as new.
static func _clear_markers(work_abs: String) -> void:
	var dir := DirAccess.open(work_abs)
	if dir == null:
		return
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if f.ends_with(".done"):
			dir.remove(f)
		f = dir.get_next()
	dir.list_dir_end()


static func _dump_blender_log(out_dir: String) -> void:
	var log_txt := FileAccess.get_file_as_string(out_dir.path_join("bake.log"))
	if not log_txt.is_empty():
		print("pavlaka: --- Blender log ---\n%s\npavlaka: --- end ---" % log_txt)


# Load each page texture fresh from disk. Returns [] if any isn't importable yet, so the
# caller can fall back to a full scan.
static func _load_pages(paths: PackedStringArray) -> Array:
	var texes: Array = []
	for p in paths:
		var tex := ResourceLoader.load(p, "", ResourceLoader.CACHE_MODE_IGNORE)
		if tex == null:
			return []
		texes.append(tex)
	return texes


# Remove page EXRs (+ .import) left by a previous, denser bake that needed more pages, so the
# folder stays tidy (the new bake wrote pages 0..n_pages-1).
static func _cleanup_stale_pages(out_dir: String, base_name: String, n_pages: int) -> void:
	var stale := PackedStringArray()
	var i := n_pages
	while FileAccess.file_exists(out_dir.path_join("%s_%d.exr" % [base_name, i])):
		stale.append(out_dir.path_join("%s_%d.exr" % [base_name, i]))
		i += 1
	for p in stale:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p + ".import"))


static func _collect(node: Node, lm: LightmapGI, out: Array[Target]) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		# hidden meshes don't bake (and are pruned from the export); skip them as targets
		if mi.visible and mi.gi_mode == GeometryInstance3D.GI_MODE_STATIC and _has_uv2(mi.mesh):
			var t := Target.new()
			t.node = mi
			t.path = lm.get_path_to(mi)
			t.name = mi.name
			t.key = "lm%d" % out.size() # unique even when node names collide (duplicated meshes)
			out.append(t)
	for c in node.get_children():
		_collect(c, lm, out)


# Build a flat export scene of copied visible meshes + lights (in world space). Avoids
# duplicating the live tree (CSG nodes break duplicate()), and only includes what the
# bake needs. All meshes occlude/bounce; bake.py bakes the ones that carry a UV2. Each target
# mesh copy is named by its unique key (node_to_key) so the bake result maps back even when
# node names collide; non-target meshes get a unique fallback name so nothing collides in glTF.
static func _build_export_scene(root: Node, targets: Array[Target]) -> Node3D:
	var node_to_key := {}
	for t in targets:
		node_to_key[t.node] = t.key
	var export_root := Node3D.new()
	export_root.name = root.name
	_gather_into(root, export_root, node_to_key)
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
					# environment_bake_panorama bakes the UNROTATED sky, so carry the
					# Environment's sky_rotation (converted to Blender's frame) to apply in Blender.
					var rot := _sky_blender_euler(e.sky_rotation)
					return {"sky_panorama": p, "ambient_color": [0.0, 0.0, 0.0], "ambient_energy": 0.0,
						"sky_rotation": [rot.x, rot.y, rot.z]}
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


# Convert Godot's Environment.sky_rotation (Y-up euler) to the equivalent Blender Mapping-node
# rotation (Z-up, XYZ euler). The rotation basis is conjugated by the Y-up->Z-up axis swap
# (Godot (x,y,z) -> Blender (x,-z,y)) so the baked sky lines up with how Godot orients it.
# NOTE: if the sky ends up rotated the wrong way / mirrored, this is the spot to adjust
# (e.g. use r.inverse(), or flip an axis sign).
static func _sky_blender_euler(godot_euler: Vector3) -> Vector3:
	if godot_euler == Vector3.ZERO:
		return Vector3.ZERO
	var r := Basis.from_euler(godot_euler)
	var s := Basis(Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(0, -1, 0)) # -90° about X
	return (s * r * s.inverse()).get_euler(EULER_ORDER_XYZ)


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


static func _gather_into(node: Node, export_root: Node3D, node_to_key: Dictionary) -> void:
	for c in node.get_children():
		if c is MeshInstance3D and (c as MeshInstance3D).is_visible_in_tree() and (c as MeshInstance3D).mesh != null:
			var mi := c as MeshInstance3D
			var copy := MeshInstance3D.new()
			# targets are named by their unique key; occluders by a unique fallback so glTF
			# never has to rename a collision (which would break the bake-result mapping).
			copy.name = node_to_key.get(mi, "occ_%d" % mi.get_instance_id())
			copy.mesh = mi.mesh
			copy.transform = mi.global_transform
			# carry each surface's EFFECTIVE material (material_override > surface override >
			# mesh material) so Blender bakes with the real albedo/emission — that's what makes
			# indirect bounces colored and lets emissive surfaces cast light.
			for s in mi.mesh.get_surface_count():
				var m := mi.get_active_material(s)
				if m != null:
					copy.set_surface_override_material(s, m)
			export_root.add_child(copy)
			copy.owner = export_root
		elif c is Light3D and (c as Light3D).is_visible_in_tree() and (c as Light3D).light_bake_mode == Light3D.BAKE_STATIC:
			var lcopy: Light3D = (c as Light3D).duplicate()
			lcopy.transform = (c as Light3D).global_transform
			export_root.add_child(lcopy)
			lcopy.owner = export_root
		_gather_into(c, export_root, node_to_key)


# map LightmapGI BakeQuality (Low/Medium/High/Ultra) to Cycles samples (denoise cleans up)
static func _samples_for_quality(q: int) -> int:
	match q:
		0: return 64    # Low
		2: return 256   # High
		3: return 512   # Ultra
	return 128          # Medium (default)


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


# Pack the targets into atlas pages at a uniform texel density (no stretching). Each mesh's
# square chunk side = sqrt(world area) * BASE_DENSITY * texel_scale (px); chunks are
# shelf-packed, and each page grows to fit its content but never exceeds max_texture_size in
# either dimension — opening a new page when it would (multi-page like the native lightmapper,
# where max_texture_size caps each atlas page). A mesh whose chunk can't fit one page is shrunk
# to fit and its name returned in "fallbacks". Returns { "page_dims": Array[Vector2i] (one per
# page), "placements": Array ({page:int, rect:Rect2i}, aligned with targets), "fallbacks":
# Array[String] }.
static func _pack_pages(targets: Array[Target], max_texture_size: int, texel_scale: float) -> Dictionary:
	var cap := maxi(64, max_texture_size)
	var inner := maxi(1, cap - ATLAS_GUTTER) # leave a gutter so nothing touches the edge
	var density: float = BASE_DENSITY * (texel_scale if texel_scale > 0.0001 else 1.0)
	var sizes: Array[int] = []
	var fallbacks: Array[String] = []
	for t in targets:
		var s := int(maxi(8, roundi(sqrt(_world_surface_area(t.node)) * density)))
		if s > inner:
			s = inner # too big for a page: shrink to fit (lower density) instead of erroring
			fallbacks.append(t.name)
		sizes.append(s)
	# place largest chunks first (better shelf packing), first-fit across pages
	var order := range(targets.size())
	order.sort_custom(func(a, b): return sizes[a] > sizes[b])
	var pages: Array = [] # each: { "bottom": int, "shelves": Array[{y,h,x}] }
	var placements: Array = []
	placements.resize(targets.size())
	for idx in order:
		var s: int = sizes[idx]
		var cell := s + ATLAS_GUTTER
		var placed := false
		for pi in pages.size():
			var pg: Dictionary = pages[pi]
			for shelf in pg["shelves"]:
				if shelf["x"] + cell <= cap and cell <= shelf["h"]:
					placements[idx] = {"page": pi, "rect": _cell_rect(shelf["x"], shelf["y"], s)}
					shelf["x"] += cell
					placed = true
					break
			if placed:
				break
			if pg["bottom"] + cell <= cap: # open a new shelf in this page
				var y: int = pg["bottom"]
				pg["shelves"].append({"y": y, "h": cell, "x": cell})
				pg["bottom"] = y + cell
				placements[idx] = {"page": pi, "rect": _cell_rect(0, y, s)}
				placed = true
				break
		if not placed: # need a new page
			pages.append({"bottom": cell, "shelves": [{"y": 0, "h": cell, "x": cell}]})
			placements[idx] = {"page": pages.size() - 1, "rect": _cell_rect(0, 0, s)}
	# size each page to its content (rounded up to a multiple of 4 for block-compression
	# safety), never exceeding the cap
	var page_dims: Array = []
	page_dims.resize(pages.size())
	for pi in pages.size():
		page_dims[pi] = Vector2i(4, 4)
	for idx in placements.size():
		var pl: Dictionary = placements[idx]
		var r: Rect2i = pl["rect"]
		var pi: int = pl["page"]
		var d: Vector2i = page_dims[pi]
		page_dims[pi] = Vector2i(
			maxi(d.x, _round_up(r.position.x + r.size.x + ATLAS_GUTTER / 2, 4)),
			maxi(d.y, _round_up(r.position.y + r.size.y + ATLAS_GUTTER / 2, 4)))
	for pi in page_dims.size():
		page_dims[pi] = (page_dims[pi] as Vector2i).min(Vector2i(cap, cap))
	return {"page_dims": page_dims, "placements": placements, "fallbacks": fallbacks}


static func _round_up(v: int, mult: int) -> int:
	@warning_ignore("integer_division")
	return ((v + mult - 1) / mult) * mult


# Content rect inside a gutter-padded cell whose top-left is (cx, cy), content side s.
static func _cell_rect(cx: int, cy: int, s: int) -> Rect2i:
	@warning_ignore("integer_division")
	var h := ATLAS_GUTTER / 2
	return Rect2i(Vector2i(cx + h, cy + h), Vector2i(s, s))


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



# Write the page's .import preset, preserving an existing UID line (so re-bakes keep stable
# UIDs that scenes/.lmbake reference) while still updating the params.
# compress=false -> mode=0 (lossless): the page keeps its exact content-fit dimensions and
# respects Max Texture Size. compress=true -> mode=2 (VRAM/BC6H): ~4x smaller VRAM, but the
# importer rounds the texture up to a power of two (wasted space, and a page may exceed Max
# Texture Size) and HDR compression can band slightly.
static func _write_exr_import(exr_res_path: String, compress: bool) -> void:
	var uid_line := ""
	if FileAccess.file_exists(exr_res_path + ".import"):
		for line in FileAccess.get_file_as_string(exr_res_path + ".import").split("\n"):
			if line.begins_with("uid="):
				uid_line = "\n" + line
				break
	var f := FileAccess.open(exr_res_path + ".import", FileAccess.WRITE)
	f.store_string("""[remap]

importer="2d_array_texture"
type="CompressedTexture2DArray"%s

[params]

compress/mode=%d
compress/channel_pack=1
mipmaps/generate=false
slices/horizontal=1
slices/vertical=1
""" % [uid_line, 2 if compress else 0])
	f.close()
