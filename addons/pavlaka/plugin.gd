@tool
extends EditorPlugin
## pavlaka EditorPlugin. Mirrors the built-in LightmapGI workflow: when a
## LightmapBlenderGI node is selected, a "Bake with Blender" button appears in the 3D
## editor toolbar and bakes that node's scene using the node's parameters.
##
## Blender path resolves from project setting "pavlaka/blender_path", else env
## PAVLAKA_BLENDER. Headless self-test: set env PAVLAKA_AUTOBAKE=1 (+ PAVLAKA_BLENDER)
## and launch with --editor --headless to run _autobake() and quit.

const SETTING_BLENDER := "pavlaka/blender_path"

var _btn: Button
var _current: LightmapBlenderGI


func _enter_tree() -> void:
	if not ProjectSettings.has_setting(SETTING_BLENDER):
		ProjectSettings.set_setting(SETTING_BLENDER, "")
	ProjectSettings.set_initial_value(SETTING_BLENDER, "")
	ProjectSettings.add_property_info({
		"name": SETTING_BLENDER,
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_GLOBAL_FILE,
		"hint_string": "*.exe,*",
	})
	ProjectSettings.set_as_basic(SETTING_BLENDER, true)

	_btn = Button.new()
	_btn.text = "Bake with Blender"
	_btn.pressed.connect(_on_bake_pressed)
	_btn.visible = false # shown only while a LightmapBlenderGI is selected
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _btn)

	if OS.get_environment("PAVLAKA_AUTOBAKE") != "":
		call_deferred("_autobake")


func _exit_tree() -> void:
	if _btn:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _btn)
		_btn.queue_free()
		_btn = null


# --- selection-driven button (like the built-in LightmapGI bake button) -----
func _handles(object: Object) -> bool:
	return object is LightmapBlenderGI


func _edit(object: Object) -> void:
	_current = object as LightmapBlenderGI


func _make_visible(visible: bool) -> void:
	if _btn:
		_btn.visible = visible


func _blender_path() -> String:
	var p: String = ProjectSettings.get_setting(SETTING_BLENDER, "")
	if not p.is_empty():
		return p
	return OS.get_environment("PAVLAKA_BLENDER")


func _on_bake_pressed() -> void:
	if _current == null:
		push_error("pavlaka: select a LightmapBlenderGI node first")
		return
	var root := EditorInterface.get_edited_scene_root()
	if root == null or not (root is Node3D):
		push_error("pavlaka: open a 3D scene first")
		return
	var err := PavlakaBaker.bake(root, _current, _blender_path(), _current.get_bake_opts())
	if err == OK:
		EditorInterface.mark_scene_as_unsaved()


# ---- headless self-test ----------------------------------------------------
func _autobake() -> void:
	print("PAVLAKA_AUTO: building test scene")
	var root := Node3D.new()
	root.name = "BakeScene"
	get_tree().root.add_child(root)

	_add_quad(root, "Floor", [Vector3(-2, 0, -2), Vector3(2, 0, -2), Vector3(2, 0, 2), Vector3(-2, 0, 2)], Vector3.UP)
	_add_quad(root, "Roof", [Vector3(-2, 2.2, -2), Vector3(2, 2.2, -2), Vector3(2, 2.2, 2), Vector3(-2, 2.2, 2)], Vector3.UP)

	var cube := MeshInstance3D.new()
	cube.name = "Occluder"
	var box := BoxMesh.new(); box.size = Vector3.ONE
	cube.mesh = box
	cube.position = Vector3(0.5, 0.7, 0.5)
	root.add_child(cube); cube.owner = root

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"; sun.light_energy = 4.0
	sun.rotation = Vector3(deg_to_rad(-55), deg_to_rad(35), 0)
	root.add_child(sun); sun.owner = root

	var lm := LightmapBlenderGI.new(); lm.name = "LightmapBlenderGI"
	root.add_child(lm); lm.owner = root

	var err := PavlakaBaker.bake(root, lm, _blender_path(), lm.get_bake_opts())
	print("PAVLAKA_AUTO: bake err=", err,
		" users=", lm.light_data.get_user_count() if lm.light_data else -1,
		" textures=", lm.light_data.get_lightmap_textures().size() if lm.light_data else -1)

	if err == OK:
		var ps := PackedScene.new()
		ps.pack(root)
		var save_err := ResourceSaver.save(ps, "res://poc/out/baked_scene.tscn")
		print("PAVLAKA_AUTO: saved baked_scene.tscn err=", save_err)
	print("PAVLAKA_AUTO: ", "PASS" if err == OK else "FAIL")
	get_tree().quit(err)


func _add_quad(root: Node, mesh_name: String, verts: Array, normal: Vector3) -> void:
	var mi := MeshInstance3D.new()
	mi.name = mesh_name
	mi.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array(verts)
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([normal, normal, normal, normal])
	var uv := PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_TEX_UV2] = uv
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mi.mesh = am
	root.add_child(mi); mi.owner = root
