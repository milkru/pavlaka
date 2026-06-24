extends Node3D
## M2a — render a REAL Blender-baked irradiance EXR through the proven M1 harness.
##
## Loads poc/out/baked.exr (linear HDR, baked by blender/bake_poc.py), wraps it in an
## externally-built LightmapGIData, and renders it on a quad. If the baked floor lighting
## (with the cube's shadow) shows up at a plausible brightness, the Blender->Godot
## irradiance/exposure/color contract holds. Screenshot -> poc/out/render_baked.png.

const EXR_PATH := "res://poc/out/baked.exr"

func _ready() -> void:
	get_window().size = Vector2i(512, 512)

	var cam := Camera3D.new()
	cam.position = Vector3(0, 0, 2.2)
	add_child(cam)
	cam.make_current()

	# --- load the Blender-baked EXR -------------------------------------------------
	var img := Image.load_from_file(ProjectSettings.globalize_path(EXR_PATH))
	if img == null:
		print("RENDER_BAKED: FAILED to load ", EXR_PATH)
		get_tree().quit(1)
		return
	print("RENDER_BAKED: loaded EXR ", img.get_width(), "x", img.get_height(),
		" fmt=", img.get_format())
	var tex := Texture2DArray.new()
	tex.create_from_images([img])

	# --- externally-built LightmapGIData (same recipe proven in M1) -----------------
	var data := LightmapGIData.new()
	data.set_lightmap_textures([tex])
	data.set_uses_spherical_harmonics(false)
	var sh := PackedColorArray(); sh.resize(9)
	data.call("_set_probe_data", {
		"bounds": AABB(Vector3(-2, -2, -2), Vector3(4, 4, 4)), # non-empty -> instance not culled
		"points": PackedVector3Array([Vector3.ZERO]), "sh": sh,
		"tetrahedra": PackedInt32Array(), "bsp": PackedInt32Array(),
		"interior": false, "baked_exposure": 1.0, "lightprobe_hash": 0,
	})

	var lm := LightmapGI.new()
	lm.name = "LightmapGI"
	add_child(lm)
	var mi := MeshInstance3D.new()
	mi.name = "Quad"
	mi.mesh = _make_quad()
	mi.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color.WHITE
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	lm.add_child(mi)

	data.add_user(NodePath("Quad"), Rect2(0, 0, 1, 1), 0, -1)
	lm.light_data = data
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
	arrays[Mesh.ARRAY_TEX_UV2] = arrays[Mesh.ARRAY_TEX_UV]
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return am

func _capture_and_quit() -> void:
	for i in 6:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var frame := get_viewport().get_texture().get_image()
	frame.save_png("res://poc/out/render_baked.png")
	print("RENDER_BAKED: center=", frame.get_pixel(256, 256), " saved render_baked.png")
	get_tree().quit()
