@tool
extends EditorPlugin
## pavlaka EditorPlugin. When a BlenderLightmapGI node is selected, a "Bake Lightmaps" button
## appears in the 3D toolbar and bakes its scene. The Blender path comes from the environment
## variable PAVLAKA_BLENDER when it is set, else from the project setting "pavlaka/blender_path"
## (auto-detected on enable).
##
## Bakes can also start without the button: [method bake_scene] from an editor script, the
## command line (`godot --editor --path <project> -- --pavlaka-bake res://scene.tscn`: bakes,
## saves, prints one JSON line, quits), or, when the godot-ai plugin is installed, its MCP tool
## "pavlaka_bake".

const SETTING_BLENDER := "pavlaka/blender_path"
## Names the Blender executable without storing its path in the project (portable setups, CI).
const ENV_BLENDER := "PAVLAKA_BLENDER"
## Command-line flag: bake the scene that follows it, save it, and quit the editor.
const BAKE_ARG := "--pavlaka-bake"
## The godot-ai MCP tool (registered only when godot-ai is installed).
const MCP_TOOL := "pavlaka_bake"
const MCP_HANDLER := "res://addons/pavlaka/mcp_bake.gd"
const PLUGIN_CFG := "res://addons/pavlaka/plugin.cfg"

var _btn: Button
var _builtin_btn: Button
var _current: BlenderLightmapGI
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

	# auto-detect Blender on first install; the user can change it in Project Settings later
	if String(ProjectSettings.get_setting(SETTING_BLENDER, "")).is_empty() and OS.get_environment(ENV_BLENDER).is_empty():
		var found := _detect_blender()
		if not found.is_empty():
			ProjectSettings.set_setting(SETTING_BLENDER, found)
			ProjectSettings.save()
			print("pavlaka: auto-detected Blender at: ", found)
		else:
			push_warning("pavlaka: no Blender found — set Project Settings → pavlaka/blender_path")

	_btn = Button.new()
	_btn.text = "Bake Lightmaps"
	_btn.pressed.connect(_on_bake_pressed)
	var theme := EditorInterface.get_editor_theme()
	if theme != null and theme.has_icon("Bake", "EditorIcons"):
		_btn.icon = theme.get_icon("Bake", "EditorIcons") # the editor's built-in bake icon
	_btn.hide() # shown only while a BlenderLightmapGI is selected
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _btn)
	_build_progress_strip()

	# drive button visibility from the editor selection (reliable across selections)
	EditorInterface.get_selection().selection_changed.connect(_on_selection_changed)
	# re-evaluate the button when settings change, so it reflects Blender-path validity live
	if not ProjectSettings.settings_changed.is_connected(_update_button):
		ProjectSettings.settings_changed.connect(_update_button)
	_on_selection_changed()

	Engine.set_meta("pavlaka_plugin", self)
	_register_mcp_tool.call_deferred(10)
	var args := OS.get_cmdline_user_args()
	var i := args.find(BAKE_ARG)
	if i >= 0 and i + 1 < args.size():
		_bake_and_quit.call_deferred(args[i + 1])


func _exit_tree() -> void:
	if Engine.has_meta("pavlaka_plugin"):
		Engine.remove_meta("pavlaka_plugin")
	var reg := _mcp_registry()
	if reg:
		reg.unregister(MCP_TOOL)
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


# show the bake button only while a BlenderLightmapGI node is selected
func _on_selection_changed() -> void:
	_current = null
	for n in EditorInterface.get_selection().get_selected_nodes():
		if n is BlenderLightmapGI:
			_current = n
			break
	_update_button()
	# BlenderLightmapGI is-a LightmapGI, so the built-in plugin also shows its bake button. Hide
	# it while our node is selected (re-hidden on reappear, see _on_builtin_vis); plain ones untouched.
	var b := _find_builtin_bake_button()
	if b and _current != null:
		b.visible = false


# single source of truth for the toolbar slot. Baking: progress strip shown. Otherwise: button
# shown only with a BlenderLightmapGI selected, disabled when the Blender path is invalid.
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


# build the inline progress strip ([icon] Baking… Ns [Cancel]); hidden until a bake starts
func _build_progress_strip() -> void:
	_progress = HBoxContainer.new()
	# match the bake button's height (theme/DPI dependent, so read it; _btn already exists here)
	var row_h := _btn.get_combined_minimum_size().y if _btn else 0.0
	if row_h > 0.0:
		_progress.custom_minimum_size = Vector2(0, row_h)
	# small spacer so the icon isn't flush against the strip's left edge
	var lead := Control.new()
	lead.custom_minimum_size = Vector2(6, 0)
	_progress.add_child(lead)
	var theme := EditorInterface.get_editor_theme()
	if theme != null and theme.has_icon("Bake", "EditorIcons"):
		var icon := TextureRect.new()
		icon.texture = theme.get_icon("Bake", "EditorIcons") # same editor bake icon as the button
		icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_progress.add_child(icon)
	_progress_label = Label.new()
	_progress_label.text = _baking_text()
	_progress_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_progress.add_child(_progress_label)
	_cancel_btn = Button.new()
	_cancel_btn.text = "Cancel"
	_cancel_btn.pressed.connect(_on_cancel_pressed)
	_progress.add_child(_cancel_btn)
	_progress.hide()
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _progress)
	# ticks once a second to refresh the elapsed time
	_progress_timer = Timer.new()
	_progress_timer.wait_time = 1.0
	_progress_timer.timeout.connect(_tick_progress)
	_progress.add_child(_progress_timer)


# "Baking Lightmaps..." + the elapsed time
func _baking_text() -> String:
	return "Baking Lightmaps...   %s" % _fmt_elapsed((Time.get_ticks_msec() - _bake_start_ms) / 1000)


func _tick_progress() -> void:
	if _progress_label == null:
		return
	if not _cancelled.is_empty() and _cancelled[0]:
		_progress_label.text = "Cancelling…"
		return
	_progress_label.text = _baking_text()


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
		# Identify the built-in bake button by its signal wiring, not its (translated) label:
		# LightmapGIEditorPlugin connects its "pressed" to its own _bake().
		for conn in (c as Button).pressed.get_connections():
			var cb: Callable = conn["callable"]
			var obj: Object = cb.get_object()
			if obj != null and obj.get_class() == "LightmapGIEditorPlugin":
				_builtin_btn = c
				if not _builtin_btn.visibility_changed.is_connected(_on_builtin_vis):
					_builtin_btn.visibility_changed.connect(_on_builtin_vis)
				return _builtin_btn
	return null


# Format an elapsed duration: "5 s" -> "2 m 5 s" -> "1 h 2 m 5 s".
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
	var env := OS.get_environment(ENV_BLENDER)
	if not env.is_empty():
		return env
	return ProjectSettings.get_setting(SETTING_BLENDER, "")


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
	# pick the highest version number, not the lexicographically-last path (so "Blender 4.10"
	# beats "Blender 4.9", which a plain string sort gets wrong).
	var best := found[0]
	for exe in found:
		if _blender_version_key(exe) > _blender_version_key(best):
			best = exe
	return best


# Sortable version key from a "...\Blender X.Y\blender.exe" path: X * 1000 + Y, or 0 if the
# folder doesn't carry a version. Keeps double-digit minor versions ordering correctly.
func _blender_version_key(exe_path: String) -> int:
	var folder := exe_path.get_base_dir().get_file() # e.g. "Blender 4.10"
	var m := RegEx.create_from_string("(\\d+)\\.(\\d+)").search(folder)
	if m == null:
		return 0
	return m.get_string(1).to_int() * 1000 + m.get_string(2).to_int()


func _on_bake_pressed() -> void:
	if _baking:
		return # re-entry guard: a bake is already running
	if _current == null:
		push_error("pavlaka: select a BlenderLightmapGI node first")
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

	# Resolve where to save the .lmbake: reuse the existing path if already baked, else prompt
	# (defaulting next to the scene; an unsaved scene has no default and is always prompted).
	var save_path := ""
	var data: LightmapGIData = _current.light_data
	if data != null and data.resource_path.begins_with("res://"):
		save_path = data.resource_path
	else:
		var default_path := _default_lmbake_path(root)
		save_path = await _prompt_save_path(default_path)
		if save_path.is_empty():
			return # cancelled

	# capture the node locally: _current follows the selection, which can change mid-bake
	var node := _current
	# remember the prior light_data path, to mark the scene unsaved only if the bake changes it
	var prev_data: LightmapGIData = node.light_data
	var prev_path := prev_data.resource_path if prev_data != null else ""

	var err := await _run_bake(root, node, blender, save_path)

	# mark unsaved only if the node now points at a different .lmbake, so a first bake isn't lost
	# on reload while a re-bake to the same path leaves the .tscn clean.
	if err == OK and is_instance_valid(node) and node.light_data != null \
			and node.light_data.resource_path != prev_path:
		EditorInterface.mark_scene_as_unsaved()


# One bake with the toolbar's progress strip (in place of the bake button; it stays up across
# selection changes). Returns OK or an error, as PavlakaBaker.bake.
func _run_bake(root: Node3D, node: BlenderLightmapGI, blender: String, save_path: String) -> int:
	_baking = true
	_cancelled = [false]
	_bake_start_ms = Time.get_ticks_msec()
	if _cancel_btn:
		_cancel_btn.disabled = false
	if _progress_label:
		_progress_label.text = _baking_text()
	_update_button()
	if _progress_timer:
		_progress_timer.start()

	var err: int = await PavlakaBaker.bake(root, node, blender, save_path, node.get_bake_opts(), _cancelled)

	if _progress_timer:
		_progress_timer.stop()
	_baking = false
	_update_button()
	return err


## Bakes the scene's first BlenderLightmapGI without any dialog and saves the scene: opens
## `scene_path` first, or bakes the open scene when it's empty. The .lmbake goes where the node's
## light data already is, else next to the scene. Returns {ok, scene, ms, data, meshes, error}.
func bake_scene(scene_path: String = "") -> Dictionary:
	if _baking:
		return {"ok": false, "error": "a bake is already running"}
	if not scene_path.is_empty():
		if not ResourceLoader.exists(scene_path):
			return {"ok": false, "scene": scene_path, "error": "no such scene"}
		EditorInterface.open_scene_from_path(scene_path)
	var root := EditorInterface.get_edited_scene_root()
	if root == null or not (root is Node3D):
		return {"ok": false, "error": "no 3D scene open"}
	if not scene_path.is_empty() and root.scene_file_path != scene_path:
		return {"ok": false, "scene": scene_path, "error": "the scene did not open"}
	var found := root.find_children("*", "BlenderLightmapGI", true, false)
	if root is BlenderLightmapGI:
		found.push_front(root)
	if found.is_empty():
		return {"ok": false, "scene": root.scene_file_path, "error": "no BlenderLightmapGI in the scene"}
	var node: BlenderLightmapGI = found[0]
	var blender := _blender_path()
	if blender.is_empty() or not FileAccess.file_exists(blender):
		return {"ok": false, "scene": root.scene_file_path, "error": "Blender not found: '%s'" % blender}
	var save_path := _default_lmbake_path(root)
	if node.light_data != null and node.light_data.resource_path.begins_with("res://"):
		save_path = node.light_data.resource_path
	if save_path.is_empty():
		return {"ok": false, "error": "save the scene first: the bake goes next to it"}
	var t0 := Time.get_ticks_msec()
	var err := await _run_bake(root, node, blender, save_path)
	var ok := err == OK and node.light_data != null
	if ok:
		EditorInterface.save_scene()
	return {"ok": ok, "scene": root.scene_file_path, "ms": Time.get_ticks_msec() - t0,
		"data": node.light_data.resource_path if node.light_data else "",
		"meshes": node.light_data.get_user_count() if node.light_data else 0,
		"error": "" if err == OK else error_string(err)}


# --pavlaka-bake: wait until the editor has opened, bake, print the result, quit.
func _bake_and_quit(scene_path: String) -> void:
	var fs := EditorInterface.get_resource_filesystem()
	while fs.is_scanning():
		await get_tree().process_frame
	for i in 10:
		await get_tree().process_frame
	var result := await bake_scene(scene_path)
	print(JSON.stringify(result))
	get_tree().quit(0 if result.get("ok", false) else 1)


## The godot-ai tool's work (mcp_bake.gd): bake, then send the result as its deferred reply
## (godot-ai's shapes: {data} on success, {status, error: {code, message}} on failure).
func mcp_bake(scene_path: String, ctx: Object) -> void:
	await get_tree().process_frame  # out of the deferred call first
	var result := await bake_scene(scene_path)
	if result.get("ok", false):
		ctx.send_deferred({"data": result})
	else:
		ctx.send_deferred({"status": "error", "error": {"code": "BAKE_FAILED",
			"message": str(result.get("error", ""))}})


# godot-ai's classes, looked up by name so pavlaka works without godot-ai installed.
func _global_script(class_name_: String) -> Script:
	for c in ProjectSettings.get_global_class_list():
		if c["class"] == class_name_:
			return load(c["path"])
	return null


func _mcp_registry() -> Object:
	var reg := _global_script("McpToolRegistry")
	return reg.get_instance() if reg else null


# Register the "pavlaka_bake" tool with godot-ai when it's there (it may start after pavlaka).
func _register_mcp_tool(tries: int) -> void:
	if not is_inside_tree():
		return
	var reg := _mcp_registry()
	var spec_script := _global_script("McpCustomToolSpec")
	if reg == null or spec_script == null:
		if tries > 0 and _global_script("McpToolRegistry") != null:
			await get_tree().create_timer(1.0).timeout
			_register_mcp_tool(tries - 1)
		return
	var spec: Object = spec_script.new()
	spec.name = MCP_TOOL
	spec.description = ("Bake a scene's lightmaps with pavlaka (Blender's Cycles) and save the scene. "
		+ "params: {scene: res:// path of a scene with a BlenderLightmapGI (empty = the open scene)}. "
		+ "Returns {ok, scene, ms, data, meshes, error}.")
	spec.params_schema = {"type": "object", "properties": {"scene": {"type": "string"}}}
	spec.script_path = MCP_HANDLER
	spec.method = &"bake"
	spec.source_path = PLUGIN_CFG
	spec.deferred = true
	spec.timeout_ms = 120000
	spec.requires_writable = true
	reg.register(spec)


# Default .lmbake path: next to the scene, named after it. "" if the scene isn't saved.
func _default_lmbake_path(root: Node) -> String:
	var scene := root.scene_file_path
	if scene.is_empty():
		return ""
	return scene.get_basename() + ".lmbake"


# Pop an EditorFileDialog to choose the .lmbake save path. Returns the res:// path, or "" if cancelled.
func _prompt_save_path(default_path: String) -> String:
	var dlg := EditorFileDialog.new()
	dlg.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
	dlg.access = EditorFileDialog.ACCESS_RESOURCES
	dlg.title = "Save Lightmap Bake"
	dlg.add_filter("*.lmbake", "Lightmap Bake")
	if not default_path.is_empty():
		dlg.current_path = default_path
	# complete via both signals, not visibility_changed (the dialog may hide before file_selected)
	var result := {"path": "", "done": false}
	dlg.file_selected.connect(func(p: String): result.path = p; result.done = true)
	dlg.canceled.connect(func(): result.done = true)
	EditorInterface.get_base_control().add_child(dlg)
	dlg.popup_file_dialog()
	while not result.done:
		await Engine.get_main_loop().process_frame
	dlg.queue_free()
	return result.path
