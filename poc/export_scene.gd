extends SceneTree
## M2c transport — build a Godot scene with TWO lightmapped meshes (Floor + Wall),
## a cube occluder, and a sun; export to glb. Each lightmapped mesh carries its own UV2.
## Lightmap targets are detected in Blender as meshes with >=2 UV layers.
##   Godot_..._console.exe --headless --path C:\Dev\pavlaka --script res://poc/export_scene.gd

func _initialize() -> void:
	var root := Node3D.new()
	root.name = "Scene"
	get_root().add_child(root)

	# floor: horizontal (XZ), full-0..1 UV2
	_add_mesh(root, "Floor", _quad([
		Vector3(-2, 0, -2), Vector3(2, 0, -2), Vector3(2, 0, 2), Vector3(-2, 0, 2)],
		Vector3(0, 1, 0)))

	# roof: a second horizontal surface elevated above everything -> fully lit, no
	# occluder shadow, so its bake is visibly different from the floor's (proves slice 1)
	_add_mesh(root, "Roof", _quad([
		Vector3(-2, 2.2, -2), Vector3(2, 2.2, -2), Vector3(2, 2.2, 2), Vector3(-2, 2.2, 2)],
		Vector3(0, 1, 0)))

	# cube occluder
	var cube := MeshInstance3D.new()
	cube.name = "Occluder"
	var box := BoxMesh.new(); box.size = Vector3.ONE
	cube.mesh = box
	cube.position = Vector3(0.5, 0.7, 0.5)
	root.add_child(cube); cube.owner = root

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_energy = 4.0
	sun.rotation = Vector3(deg_to_rad(-55), deg_to_rad(35), 0)
	root.add_child(sun); sun.owner = root

	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	print("EXPORT_SCENE: append err=", doc.append_from_scene(root, state))
	DirAccess.make_dir_recursive_absolute("res://poc/out")
	print("EXPORT_SCENE: write err=", doc.write_to_filesystem(state, "res://poc/out/scene.glb"))
	quit()

func _add_mesh(root: Node, mesh_name: String, mesh: ArrayMesh) -> void:
	var mi := MeshInstance3D.new()
	mi.name = mesh_name
	mi.mesh = mesh
	mi.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	root.add_child(mi); mi.owner = root

func _quad(verts: Array, normal: Vector3) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array(verts)
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([normal, normal, normal, normal])
	var uv := PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_TEX_UV2] = uv # full 0..1 lightmap UV
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return am
