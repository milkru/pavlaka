@tool
extends EditorScript
## Step 1a — construct + save + reload a LightmapGIData entirely from script.
##
## Proves the core go/no-go claim against the real engine (no scene, no EXR, no
## rendering): every setter needed to populate a LightmapGIData is reachable from
## GDScript, and the resource round-trips through ResourceSaver/ResourceLoader.
##
## HOW TO RUN: open this file in the Godot 4.7 script editor, then File > Run
## (Ctrl+Shift+X). Watch the Output panel for PASS/FAIL lines.

func _run() -> void:
	print("=== pavlaka 1a: LightmapGIData construct/save/reload smoke test ===")

	var data := LightmapGIData.new()

	# --- 1x1 placeholder atlas (HDR RGBA, matches Godot's lightmap format) -------
	# A real bake supplies an imported CompressedTexture2DArray; for this test an
	# in-memory Texture2DArray is enough — we are testing construction, not pixels.
	var img := Image.create(1, 1, false, Image.FORMAT_RGBAH)
	img.set_pixel(0, 0, Color(1.0, 1.0, 1.0, 1.0))
	var tex := Texture2DArray.new()
	var tex_err := tex.create_from_images([img])
	_check("create_from_images", tex_err == OK)

	# --- populate via the script-reachable setters (see RESEARCH.md) -------------
	data.set_lightmap_textures([tex])
	data.set_uses_spherical_harmonics(false) # non-directional: keep this AND packed-directional false

	# one user. sub_instance = -1 for a normal MeshInstance3D.
	# NodePath is resolved relative to the LightmapGI node at runtime (1b), not here.
	data.add_user(NodePath("Plane"), Rect2(0, 0, 1, 1), 0, -1)

	# minimal probe/capture data: every key is mandatory on load, empty is valid.
	# set_capture_data() is C++-only, but the bound "_set_probe_data" hook reaches it.
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

	# --- save -> reload -> verify ------------------------------------------------
	var path := "res://poc/out/smoke.lmbake"
	DirAccess.make_dir_recursive_absolute("res://poc/out")
	var save_err := ResourceSaver.save(data, path)
	_check("ResourceSaver.save == OK", save_err == OK)

	var reloaded := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	_check("reloaded is LightmapGIData", reloaded is LightmapGIData)
	if reloaded is LightmapGIData:
		_check("reloaded user_count == 1", reloaded.get_user_count() == 1)
		_check("reloaded user_path == Plane", reloaded.get_user_path(0) == NodePath("Plane"))
		_check("reloaded has 1 texture", reloaded.get_lightmap_textures().size() == 1)
		_check("reloaded SH flag is false", reloaded.is_using_spherical_harmonics() == false)

	print("=== done — if all lines say PASS, the resource API holds on 4.7 ===")

func _check(label: String, ok: bool) -> void:
	print(("PASS " if ok else "FAIL ") + label)
