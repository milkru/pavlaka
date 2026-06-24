extends Node3D
## Step 1b — does an externally-built LightmapGIData actually RENDER?
##
## Builds a recognizable gradient atlas in memory, wraps it in a LightmapGIData via the
## same script-only API as 1a, binds it to a LightmapGI node, renders a frame, and saves
## a screenshot to res://poc/out/render.png. No lights, no environment: the ONLY light
## contribution is the lightmap, so whatever shows on the quad came from our resource.
##
## Run windowed (NOT --headless, we need real rendering):
##   Godot_..._console.exe --path C:\Dev\pavlaka

const ATLAS := 64

func _ready() -> void:
	get_window().size = Vector2i(512, 512)

	# camera looking at the quad at origin
	var cam := Camera3D.new()
	cam.position = Vector3(0.0, 0.0, 2.2)
	add_child(cam)
	cam.make_current()

	# --- recognizable gradient atlas (in-memory; live render needs no imported asset) -
	var img := Image.create(ATLAS, ATLAS, false, Image.FORMAT_RGBAH)
	for y in ATLAS:
		for x in ATLAS:
			# R ramps along X, G ramps along Y -> proves UV2-driven atlas sampling is live
			img.set_pixel(x, y, Color(float(x) / (ATLAS - 1), float(y) / (ATLAS - 1), 0.25, 1.0))
	var tex := Texture2DArray.new()
	var cerr := tex.create_from_images([img])
	print("RENDER_TEST: tex create=", cerr, " layers=", tex.get_layers(),
		" size=", tex.get_width(), "x", tex.get_height(), " fmt=", tex.get_format())

	# --- externally-built LightmapGIData (identical API to 1a) ----------------------
	var data := LightmapGIData.new()
	data.set_lightmap_textures([tex])
	data.set_uses_spherical_harmonics(false)
	# CRITICAL: set_capture_data() only applies our bounds when points is NON-empty
	# (lightmap_gi.cpp:238). With empty points it forces bounds=AABB(), giving the
	# lightmap instance a zero cull AABB -> it's never gathered -> nothing renders.
	# So supply one dummy probe (+9 SH colors); tetrahedra/bsp may stay empty.
	var sh := PackedColorArray()
	sh.resize(9) # 9 SH coefficients per point; black is fine (no dynamic objects use it)
	data.call("_set_probe_data", {
		"bounds": AABB(Vector3(-2, -2, -2), Vector3(4, 4, 4)),
		"points": PackedVector3Array([Vector3.ZERO]),
		"sh": sh,
		"tetrahedra": PackedInt32Array(),
		"bsp": PackedInt32Array(),
		"interior": false,
		"baked_exposure": 1.0, "lightprobe_hash": 0,
	})

	# --- LightmapGI node with the quad as its child (NodePath resolves from the node) -
	var lm := LightmapGI.new()
	lm.name = "LightmapGI"
	add_child(lm)

	var mi := MeshInstance3D.new()
	mi.name = "Quad"
	mi.mesh = _make_quad()
	mi.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color.WHITE # lightmap is irradiance; albedo (white) * sample = sample
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED # don't cull the quad regardless of winding
	mi.material_override = mat
	lm.add_child(mi)

	data.add_user(NodePath("Quad"), Rect2(0, 0, 1, 1), 0, -1)
	lm.light_data = data # set_light_data() binds users via _assign_lightmaps() (in-tree)
	print("RENDER_TEST: light_data set, user_count=", lm.light_data.get_user_count(),
		" resolves_quad=", lm.get_node_or_null(lm.light_data.get_user_path(0)) != null)

	_capture_and_quit()

func _make_quad() -> ArrayMesh:
	var n := Vector3(0, 0, 1)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-1, -1, 0), Vector3(1, -1, 0), Vector3(1, 1, 0), Vector3(-1, 1, 0)])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([n, n, n, n])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([
		Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)])
	# UV2 spans the full 0..1 so the whole gradient atlas shows across the quad.
	arrays[Mesh.ARRAY_TEX_UV2] = arrays[Mesh.ARRAY_TEX_UV]
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return am

func _capture_and_quit() -> void:
	for i in 6:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	print("RENDER_TEST: active_cam=", get_viewport().get_camera_3d(),
		" vp_size=", get_viewport().get_visible_rect().size)
	var frame := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute("res://poc/out")
	frame.save_png("res://poc/out/render.png")
	print("RENDER_TEST: center(quad)=", frame.get_pixel(256, 256),
		" corner(bg)=", frame.get_pixel(8, 8))
	print("RENDER_TEST: saved res://poc/out/render.png")
	get_tree().quit()
