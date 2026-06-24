extends SceneTree
## Transport de-risk: export a mesh with a DISTINCT UV2 to glTF, so we can verify in
## Blender whether Godot's glTF export carries the second UV channel (TEXCOORD_1).
##   Godot_..._console.exe --headless --path C:\Dev\pavlaka --script res://poc/export_gltf.gd

func _initialize() -> void:
	var root := Node3D.new()
	root.name = "Scene"
	get_root().add_child(root)

	var mi := MeshInstance3D.new()
	mi.name = "Floor"
	mi.mesh = _make_quad()
	root.add_child(mi)
	mi.owner = root

	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_scene(root, state)
	print("EXPORT_GLTF: append err=", err)
	DirAccess.make_dir_recursive_absolute("res://poc/out")
	err = doc.write_to_filesystem(state, "res://poc/out/scene.glb")
	print("EXPORT_GLTF: write err=", err, " -> res://poc/out/scene.glb")
	quit()

func _make_quad() -> ArrayMesh:
	var n := Vector3(0, 0, 1)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-1, -1, 0), Vector3(1, -1, 0), Vector3(1, 1, 0), Vector3(-1, 1, 0)])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([n, n, n, n])
	# UV0 spans full 0..1
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([
		Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)])
	# UV2 is a DISTINCT inner sub-rect 0.25..0.75 so we can detect it specifically
	arrays[Mesh.ARRAY_TEX_UV2] = PackedVector2Array([
		Vector2(0.25, 0.75), Vector2(0.75, 0.75), Vector2(0.75, 0.25), Vector2(0.25, 0.25)])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return am
