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
var _builtin_btn: Button
var _current: LightmapBlenderGI
var _baking := false
# inline progress strip shown in the toolbar in place of the bake button while baking
var _progress: HBoxContainer
var _progress_label: Label
var _progress_timer: Timer
var _cancel_btn: Button
var _cancelled: Array = [false]
var _bake_start_ms := 0


func _enter_tree() -> void:
	_baking = false # reset on (re)load so an interrupted bake can't leave it stuck
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

	# auto-detect Blender on first install (when the path is still empty). The user can
	# always change it in Project Settings (e.g. after updating Blender / with multiple).
	if String(ProjectSettings.get_setting(SETTING_BLENDER, "")).is_empty():
		var found := _detect_blender()
		if not found.is_empty():
			ProjectSettings.set_setting(SETTING_BLENDER, found)
			ProjectSettings.save()
			print("pavlaka: auto-detected Blender at: ", found)
		else:
			push_warning("pavlaka: no Blender found — set Project Settings → pavlaka/blender_path")

	_btn = Button.new()
	_btn.text = "Bake with Blender"
	_btn.pressed.connect(_on_bake_pressed)
	var theme := EditorInterface.get_editor_theme()
	if theme != null and theme.has_icon("Bake", "EditorIcons"):
		_btn.icon = theme.get_icon("Bake", "EditorIcons") # match the built-in bake button
	_btn.hide() # shown only while a LightmapBlenderGI is selected
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _btn)
	_build_progress_strip()

	# drive button visibility from the editor selection (reliable across selections)
	EditorInterface.get_selection().selection_changed.connect(_on_selection_changed)
	# also re-evaluate the button when project settings change (e.g. the Blender path is
	# edited/cleared while the node stays selected), so it reflects path validity live
	if not ProjectSettings.settings_changed.is_connected(_update_button):
		ProjectSettings.settings_changed.connect(_update_button)
	_on_selection_changed()

	if OS.get_environment("PAVLAKA_AUTOBAKE") != "":
		call_deferred("_autobake")


func _exit_tree() -> void:
	var sel := EditorInterface.get_selection()
	if sel.selection_changed.is_connected(_on_selection_changed):
		sel.selection_changed.disconnect(_on_selection_changed)
	if ProjectSettings.settings_changed.is_connected(_update_button):
		ProjectSettings.settings_changed.disconnect(_update_button)
	if _btn:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _btn)
		_btn.queue_free()
		_btn = null
	if _progress:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _progress)
		_progress.queue_free()
		_progress = null


# show the bake button only while a LightmapBlenderGI node is selected
func _on_selection_changed() -> void:
	_current = null
	for n in EditorInterface.get_selection().get_selected_nodes():
		if n is LightmapBlenderGI:
			_current = n
			break
	_update_button()
	# LightmapBlenderGI is-a LightmapGI, so Godot's built-in editor plugin also shows its
	# "Bake Lightmaps" button. Hide it while our node is selected (and re-hide if the
	# built-in plugin pops it back up — see _on_builtin_vis). Plain LightmapGI nodes are
	# unaffected (then _current is null and we leave the built-in button alone).
	var b := _find_builtin_bake_button()
	if b and _current != null:
		b.visible = false


# single source of truth for the toolbar slot. While baking, the progress strip replaces
# the button and stays visible regardless of selection. Otherwise the button shows only
# with a LightmapBlenderGI selected, disabled when the Blender path is unset/invalid.
func _update_button() -> void:
	if _btn == null:
		return
	if _baking:
		_btn.visible = false
		if _progress:
			_progress.visible = true
		return
	if _progress:
		_progress.visible = false
	_btn.visible = _current != null
	var path := _blender_path()
	var path_ok := not path.is_empty() and FileAccess.file_exists(path)
	_btn.disabled = not path_ok
	_btn.tooltip_text = "" if path_ok else "Set the Blender path in Project Settings → pavlaka/blender_path"


# build the inline progress strip ([logo] Baking… Ns [Cancel]); hidden until a bake starts
func _build_progress_strip() -> void:
	_progress = HBoxContainer.new()
	_progress.add_theme_constant_override("separation", 6)
	var icon_path := (get_script() as Script).resource_path.get_base_dir().path_join("blender_icon.png")
	if ResourceLoader.exists(icon_path):
		var icon := TextureRect.new()
		icon.texture = load(icon_path)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.custom_minimum_size = Vector2(16, 16)
		icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_progress.add_child(icon)
	_progress_label = Label.new()
	_progress_label.text = "Baking… 0 s"
	_progress_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_progress.add_child(_progress_label)
	_cancel_btn = Button.new()
	_cancel_btn.text = "Cancel"
	_cancel_btn.set_theme_type_variation("FlatButton") # match the toolbar's flat buttons
	_cancel_btn.pressed.connect(_on_cancel_pressed)
	_progress.add_child(_cancel_btn)
	_progress.hide()
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _progress)
	# drives the elapsed counter once per second while baking
	_progress_timer = Timer.new()
	_progress_timer.wait_time = 1.0
	_progress_timer.timeout.connect(_tick_progress)
	_progress.add_child(_progress_timer)


func _tick_progress() -> void:
	if _progress_label == null:
		return
	if not _cancelled.is_empty() and _cancelled[0]:
		_progress_label.text = "Cancelling…"
	else:
		_progress_label.text = "Baking… %s" % _fmt_elapsed((Time.get_ticks_msec() - _bake_start_ms) / 1000)


func _on_cancel_pressed() -> void:
	_cancelled[0] = true
	if _cancel_btn:
		_cancel_btn.disabled = true
	if _progress_label:
		_progress_label.text = "Cancelling…"


func _find_builtin_bake_button() -> Button:
	if _builtin_btn != null and is_instance_valid(_builtin_btn):
		return _builtin_btn
	if _btn == null or _btn.get_parent() == null:
		return null
	for c in _btn.get_parent().get_children():
		if c == _btn or not (c is Button):
			continue
		# Identify Godot's built-in bake button by its signal wiring, not its label:
		# LightmapGIEditorPlugin connects the button's "pressed" signal to its own _bake().
		# Matching the object's class is language-independent (the "Bake Lightmaps" text is
		# translated in non-English editors).
		for conn in (c as Button).pressed.get_connections():
			var cb: Callable = conn["callable"]
			var obj: Object = cb.get_object()
			if obj != null and obj.get_class() == "LightmapGIEditorPlugin":
				_builtin_btn = c
				if not _builtin_btn.visibility_changed.is_connected(_on_builtin_vis):
					_builtin_btn.visibility_changed.connect(_on_builtin_vis)
				return _builtin_btn
	return null


# Format an elapsed duration, promoting to minutes/hours only once it passes each limit:
# "5 s" -> "2 m 5 s" -> "1 h 2 m 5 s".
func _fmt_elapsed(total_seconds: int) -> String:
	var s := total_seconds % 60
	var m := (total_seconds / 60) % 60
	var h := total_seconds / 3600
	if h > 0:
		return "%d h %d m %d s" % [h, m, s]
	if m > 0:
		return "%d m %d s" % [m, s]
	return "%d s" % s


# re-hide the built-in bake button whenever it reappears while our node is selected
func _on_builtin_vis() -> void:
	if _current != null and _builtin_btn != null and _builtin_btn.visible:
		_builtin_btn.visible = false


func _blender_path() -> String:
	var p: String = ProjectSettings.get_setting(SETTING_BLENDER, "")
	if not p.is_empty():
		return p
	return OS.get_environment("PAVLAKA_BLENDER")


# Find a Blender executable: first on PATH, then in common install locations.
func _detect_blender() -> String:
	var out: Array = []
	var which := "where" if OS.get_name() == "Windows" else "which"
	if OS.execute(which, ["blender"], out) == 0 and not out.is_empty():
		var first := String(out[0]).strip_edges().split("\n")[0].strip_edges()
		if not first.is_empty() and FileAccess.file_exists(first):
			return first
	match OS.get_name():
		"Windows":
			return _scan_windows_blender()
		"macOS":
			var p := "/Applications/Blender.app/Contents/MacOS/Blender"
			return p if FileAccess.file_exists(p) else ""
		_:
			for p in ["/usr/bin/blender", "/usr/local/bin/blender", "/snap/bin/blender",
					"/var/lib/flatpak/exports/bin/org.blender.Blender"]:
				if FileAccess.file_exists(p):
					return p
	return ""


# Newest "Blender X.Y/blender.exe" under Program Files\Blender Foundation.
func _scan_windows_blender() -> String:
	var found := PackedStringArray()
	var bases := PackedStringArray([
		"C:/Program Files/Blender Foundation", "C:/Program Files (x86)/Blender Foundation"])
	for base in bases:
		var d := DirAccess.open(base)
		if d == null:
			continue
		d.list_dir_begin()
		var name := d.get_next()
		while name != "":
			if d.current_is_dir() and name.begins_with("Blender"):
				var exe := base.path_join(name).path_join("blender.exe")
				if FileAccess.file_exists(exe):
					found.append(exe)
			name = d.get_next()
		d.list_dir_end()
	if found.is_empty():
		return ""
	found.sort() # lexicographic; last is the newest-versioned folder
	return found[found.size() - 1]


func _on_bake_pressed() -> void:
	if _baking:
		return # re-entry guard: a bake is already running
	if _current == null:
		push_error("pavlaka: select a LightmapBlenderGI node first")
		return
	var root := EditorInterface.get_edited_scene_root()
	if root == null or not (root is Node3D):
		push_error("pavlaka: open a 3D scene first")
		return

	var blender := _blender_path()
	if blender.is_empty():
		push_error("pavlaka: Blender path not set — set it in Project Settings → pavlaka/blender_path")
		return
	if not FileAccess.file_exists(blender):
		push_error("pavlaka: Blender not found at '%s' — fix Project Settings → pavlaka/blender_path" % blender)
		return

	# Show the inline progress strip in the toolbar (in place of the bake button). It stays
	# visible regardless of selection while baking; the editor remains fully usable since the
	# bake runs non-blocking.
	_baking = true
	_cancelled = [false]
	_bake_start_ms = Time.get_ticks_msec()
	if _cancel_btn:
		_cancel_btn.disabled = false
	if _progress_label:
		_progress_label.text = "Baking… 0 s"
	_update_button()
	if _progress_timer:
		_progress_timer.start()

	var err: int = await PavlakaBaker.bake(root, _current, blender, _current.get_bake_opts(), Callable(), _cancelled)

	if _progress_timer:
		_progress_timer.stop()
	if err == OK:
		EditorInterface.mark_scene_as_unsaved()
	_baking = false
	_update_button()


# ---- headless self-test ----------------------------------------------------
func _autobake() -> void:
	# wait for the editor's initial filesystem scan to finish, so this represents a
	# real button click in a settled editor (not a startup-time race)
	var efs := EditorInterface.get_resource_filesystem()
	while efs.is_scanning():
		await Engine.get_main_loop().process_frame
	for _i in 30:
		await Engine.get_main_loop().process_frame

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
	sun.light_bake_mode = Light3D.BAKE_STATIC
	sun.rotation = Vector3(deg_to_rad(-55), deg_to_rad(35), 0)
	root.add_child(sun); sun.owner = root

	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = Sky.new()
	env.sky.sky_material = ProceduralSkyMaterial.new()
	we.environment = env
	root.add_child(we); we.owner = root

	var lm := LightmapBlenderGI.new(); lm.name = "LightmapBlenderGI"
	root.add_child(lm); lm.owner = root

	var err: int = await PavlakaBaker.bake(root, lm, _blender_path(), lm.get_bake_opts())
	print("PAVLAKA_AUTO: bake err=", err,
		" users=", lm.light_data.get_user_count() if lm.light_data else -1,
		" textures=", lm.light_data.get_lightmap_textures().size() if lm.light_data else -1)
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
