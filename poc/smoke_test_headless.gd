extends SceneTree
## Headless variant of Step 1a — same construct/save/reload checks, but runnable from
## the command line (no editor, no rendering needed):
##
##   Godot_v4.7-stable_win64.exe --headless --path C:\Dev\pavlaka \
##       --script res://poc/smoke_test_headless.gd
##
## Resource/Image/ResourceSaver all work under --headless (dummy rendering driver),
## so this exercises the full resource API claim without opening the editor.

var _failures := 0

func _initialize() -> void:
	print("=== pavlaka 1a (headless): LightmapGIData construct/save/reload ===")

	var data := LightmapGIData.new()

	var img := Image.create(1, 1, false, Image.FORMAT_RGBAH)
	img.set_pixel(0, 0, Color(1.0, 1.0, 1.0, 1.0))
	var tex := Texture2DArray.new()
	_check("create_from_images", tex.create_from_images([img]) == OK)

	data.set_lightmap_textures([tex])
	data.set_uses_spherical_harmonics(false)
	data.add_user(NodePath("Plane"), Rect2(0, 0, 1, 1), 0, -1)
	data.call("_set_probe_data", {
		"bounds": AABB(),
		"points": PackedVector3Array(),
		"tetrahedra": PackedInt32Array(),
		"bsp": PackedInt32Array(),
		"sh": PackedColorArray(),
		"interior": false,
		"baked_exposure": 1.0,
		"lightprobe_hash": 0,
	})
	_check("user_count == 1 before save", data.get_user_count() == 1)

	var path := "res://poc/out/smoke.lmbake"
	DirAccess.make_dir_recursive_absolute("res://poc/out")
	_check("ResourceSaver.save == OK", ResourceSaver.save(data, path) == OK)

	var reloaded := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	_check("reloaded is LightmapGIData", reloaded is LightmapGIData)
	if reloaded is LightmapGIData:
		_check("reloaded user_count == 1", reloaded.get_user_count() == 1)
		_check("reloaded user_path == Plane", reloaded.get_user_path(0) == NodePath("Plane"))
		_check("reloaded has 1 texture", reloaded.get_lightmap_textures().size() == 1)
		_check("reloaded SH flag false", reloaded.is_using_spherical_harmonics() == false)

	print("=== RESULT: " + ("ALL PASS" if _failures == 0 else str(_failures) + " FAILURE(S)") + " ===")
	quit(_failures)

func _check(label: String, ok: bool) -> void:
	if not ok:
		_failures += 1
	print(("PASS " if ok else "FAIL ") + label)
