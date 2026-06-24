extends Node3D
## M2c multi-mesh proof: load N per-mesh EXR slices, combine them via
## set_lightmap_textures([...]) (Godot stacks them into one layered atlas), and render
## one quad per mesh, each sampling its own slice_index. Confirms per-slice (no packing
## logic) works and exercises non-zero slice_index. -> poc/out/render_multi.png

const META := "res://poc/out/baked.json"

func _ready() -> void:
	get_window().size = Vector2i(640, 360)
	var cam := Camera3D.new()
	cam.position = Vector3(0, 0, 4.0)
	add_child(cam); cam.make_current()

	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(META))
	var meshes: Array = meta.get("meshes", [])
	print("RENDER_MULTI: ", meshes.size(), " slices from metadata")

	# load each slice EXR as a 1-layer texture; order by slice_index
	var textures: Array = []
	textures.resize(meshes.size())
	for m in meshes:
		var img := Image.load_from_file(ProjectSettings.globalize_path(
			"res://poc/out/baked_%d.exr" % int(m["slice_index"])))
		var t := Texture2DArray.new()
		t.create_from_images([img])
		textures[int(m["slice_index"])] = t

	var data := LightmapGIData.new()
	data.set_lightmap_textures(textures) # >1 texture -> Godot combines into a layered atlas
	data.set_uses_spherical_harmonics(false)
	var sh := PackedColorArray(); sh.resize(9)
	data.call("_set_probe_data", {
		"bounds": AABB(Vector3(-4, -4, -4), Vector3(8, 8, 8)),
		"points": PackedVector3Array([Vector3.ZERO]), "sh": sh,
		"tetrahedra": PackedInt32Array(), "bsp": PackedInt32Array(),
		"interior": false, "baked_exposure": 1.0, "lightprobe_hash": 0,
	})

	var lm := LightmapGI.new(); lm.name = "LightmapGI"; add_child(lm)
	var n := meshes.size()
	for i in n:
		var m: Dictionary = meshes[i]
		var mi := MeshInstance3D.new()
		mi.name = "Q%d" % i
		mi.mesh = _make_quad()
		mi.gi_mode = GeometryInstance3D.GI_MODE_STATIC
		mi.position = Vector3((i - (n - 1) * 0.5) * 2.2, 0, 0)
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color.WHITE
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mi.material_override = mat
		lm.add_child(mi)
		var uv: Array = m["uv_scale"]
		data.add_user(NodePath("Q%d" % i), Rect2(uv[0], uv[1], uv[2], uv[3]),
			int(m["slice_index"]), -1)
		print("RENDER_MULTI: Q%d '%s' slice=%d" % [i, m["name"], int(m["slice_index"])])

	lm.light_data = data
	_capture_and_quit(n)

func _make_quad() -> ArrayMesh:
	var n := Vector3(0, 0, 1)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-0.9, -0.9, 0), Vector3(0.9, -0.9, 0), Vector3(0.9, 0.9, 0), Vector3(-0.9, 0.9, 0)])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([n, n, n, n])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([
		Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)])
	arrays[Mesh.ARRAY_TEX_UV2] = arrays[Mesh.ARRAY_TEX_UV]
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return am

func _capture_and_quit(n: int) -> void:
	for i in 6:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var frame := get_viewport().get_texture().get_image()
	frame.save_png("res://poc/out/render_multi.png")
	# sample the center of each quad
	var w := frame.get_width()
	for i in n:
		var cx := int((float(i) + 0.5) / float(n) * w)
		print("RENDER_MULTI: Q%d center px=%s" % [i, frame.get_pixel(cx, frame.get_height() / 2)])
	print("RENDER_MULTI: saved render_multi.png")
	get_tree().quit()
