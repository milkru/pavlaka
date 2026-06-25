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


# single source of truth for the button: shown only with a LightmapBlenderGI selected,
# and disabled while baking or when the Blender path is unset/invalid (with a tooltip).
func _update_button() -> void:
	if _btn == null:
		return
	_btn.visible = _current != null
	var path := _blender_path()
	var path_ok := not path.is_empty() and FileAccess.file_exists(path)
	_btn.disabled = _baking or not path_ok
	_btn.tooltip_text = "" if path_ok else "Set the Blender path in Project Settings → pavlaka/blender_path"


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


# Put the Blender logo on the bake dialog's title bar. Only works when the dialog is a
# native OS window — Godot's embedded subwindow title bar has no icon slot, and
# get_window_id() there is the editor's main window, so we'd clobber the editor's icon.
# Silently skipped if the icon resource is absent.
func _set_window_icon(dlg: Window) -> void:
	if dlg.is_embedded():
		return
	var tex := _load_addon_texture("blender_logo_kit/square/blender_icon_128x128.png")
	if tex != null:
		DisplayServer.window_set_icon(tex.get_image(), dlg.get_window_id())


# Load an image shipped in the addon as its imported Texture2D. Using load() (rather than
# Image.load_from_file) avoids the "won't work on export" warning and reuses the editor's
# imported copy. Returns null if the resource isn't present/importable.
func _load_addon_texture(rel_path: String) -> Texture2D:
	var p := (get_script() as Script).resource_path.get_base_dir().path_join(rel_path)
	if not ResourceLoader.exists(p):
		return null
	return load(p) as Texture2D


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

	_baking = true
	_update_button()

	# progress dialog so the editor shows feedback instead of appearing frozen. Forced
	# NON-exclusive (AcceptDialog defaults to exclusive): an exclusive popup collides with
	# the editor's reimport ProgressDialog during import and crashes (progress_dialog.cpp).
	# Non-exclusive lets both coexist, so the spinner can stay up through the whole bake.
	var cancelled := [false]
	var dlg := AcceptDialog.new()
	dlg.exclusive = false
	dlg.title = "Bake with Blender"
	dlg.get_ok_button().hide()
	dlg.unresizable = true
	dlg.min_size = Vector2i(300, 0)

	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 18)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)

	# spinner (a rotating Reload icon) + status line "In the oven…  Ns", right-aligned
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 8)
	var spin := TextureRect.new()
	var th := EditorInterface.get_editor_theme()
	if th != null and th.has_icon("Reload", "EditorIcons"):
		spin.texture = th.get_icon("Reload", "EditorIcons")
	spin.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	spin.custom_minimum_size = Vector2(18, 18)
	spin.pivot_offset = Vector2(9, 9) # rotate around its center
	var status := Label.new()
	status.text = "In the oven…  0 s"
	status.modulate = Color(1, 1, 1, 0.85)
	row.add_child(spin)
	row.add_child(status)

	# small Blender logo tucked into the lower-right. EXPAND_IGNORE_SIZE so the TextureRect
	# doesn't inherit the texture's full 1800x550 size; custom_minimum_size then controls it.
	var logo := TextureRect.new()
	var logo_tex := _load_addon_texture("blender_logo_kit/blender_logo_socket.png")
	if logo_tex != null:
		logo.texture = logo_tex
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT
	logo.custom_minimum_size = Vector2(120, 37)
	logo.size_flags_horizontal = Control.SIZE_SHRINK_END # pin to the right

	vb.add_child(row)
	vb.add_child(logo)
	margin.add_child(vb)
	dlg.add_child(margin)

	# tick elapsed seconds into the status line (rendering dominates, so a single running
	# counter is more useful than per-stage labels)
	var start_ms := Time.get_ticks_msec()
	var tick := func():
		if not is_instance_valid(status):
			return
		if not cancelled.is_empty() and cancelled[0]:
			status.text = "Cancelling…"
		else:
			status.text = "In the oven…  %d s" % ((Time.get_ticks_msec() - start_ms) / 1000)
	var timer := Timer.new()
	timer.wait_time = 1.0
	timer.autostart = true
	timer.timeout.connect(tick)
	dlg.add_child(timer)

	var on_cancel := func():
		cancelled[0] = true
		if is_instance_valid(status):
			status.text = "Cancelling…"
	dlg.add_button("Cancel", true, "cancel").pressed.connect(on_cancel)
	dlg.canceled.connect(on_cancel) # closing the dialog (X / Esc) also cancels the bake
	EditorInterface.get_base_control().add_child(dlg)
	dlg.popup_centered()
	_set_window_icon(dlg)

	# spin the icon continuously (tween must be created once the node is in the tree)
	if spin.texture != null:
		var tw := spin.create_tween().set_loops()
		tw.tween_property(spin, "rotation", TAU, 1.2).from(0.0)

	var err: int = await PavlakaBaker.bake(root, _current, blender, _current.get_bake_opts(), Callable(), cancelled)

	if is_instance_valid(dlg):
		dlg.queue_free()
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
