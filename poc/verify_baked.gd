extends Node3D
## Visual verification of the EditorPlugin output: load the baked_scene.tscn the plugin
## produced (LightmapGI + assigned .lmbake), and render the real 3D scene. The floor
## should show baked lighting with the cube's shadow. -> poc/out/verify_baked.png

func _ready() -> void:
	get_window().size = Vector2i(640, 480)
	var baked := load("res://poc/out/baked_scene.tscn") as PackedScene
	var scene := baked.instantiate()
	add_child(scene)
	# disable real-time lights so ONLY the baked lightmap lights the scene
	# (otherwise the still-active sun double-lights and washes out the baked shadow)
	_disable_lights(scene)


func _disable_lights(n: Node) -> void:
	if n is Light3D:
		(n as Light3D).visible = false
	for c in n.get_children():
		_disable_lights(c)

	var cam := Camera3D.new()
	cam.position = Vector3(3.0, 1.2, 3.0)
	add_child(cam)
	cam.look_at(Vector3(0, 0.2, 0), Vector3.UP)
	cam.make_current()

	for i in 8:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://poc/out/verify_baked.png")
	print("VERIFY_BAKED: saved verify_baked.png")
	get_tree().quit()
