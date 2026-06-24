extends SceneTree
## Test: does an ambient-only bake (no lights) give baked AO? Floor (UV2) + a cube
## hovering just above it. No DirectionalLight -> only world ambient lights the scene.
##   Godot_..._console.exe --headless --path C:\Dev\pavlaka --script res://poc/export_ambient.gd

func _initialize() -> void:
	var root := Node3D.new(); root.name = "Scene"
	get_root().add_child(root)

	var mi := MeshInstance3D.new()
	mi.name = "Floor"
	mi.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-2, 0, -2), Vector3(2, 0, -2), Vector3(2, 0, 2), Vector3(-2, 0, 2)])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP])
	var uv := PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_TEX_UV2] = uv
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mi.mesh = am
	root.add_child(mi); mi.owner = root

	# cube hovering just above the floor -> occludes the ambient dome -> AO underneath
	var cube := MeshInstance3D.new()
	cube.name = "Occluder"
	var box := BoxMesh.new(); box.size = Vector3(1.5, 1.0, 1.5)
	cube.mesh = box
	cube.position = Vector3(0, 0.55, 0)
	root.add_child(cube); cube.owner = root

	# NO LIGHTS — ambient only.

	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	doc.append_from_scene(root, state)
	DirAccess.make_dir_recursive_absolute("res://poc/out")
	print("EXPORT_AMBIENT: write err=", doc.write_to_filesystem(state, "res://poc/out/scene.glb"))
	quit()
