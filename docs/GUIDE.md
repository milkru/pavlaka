# pavlaka Guide

How to use the pavlaka lightmap baker: baking a scene, the node settings, scripting and a few
things to watch out for. For the overview and install steps, see the [README](../README.md).

## Baking a scene

The workflow matches the regular `LightmapGI`.

1. Add a **`BlenderLightmapGI`** node to your scene (Create Node dialog).
2. Make sure your static meshes have a **UV2**. For imported meshes, open the Import dock, set
   **Meshes, Light Baking** to **Static Lightmaps**, then Reimport. Meshes without a UV2 are
   skipped.
3. Add at least one light and set its **Bake Mode** to **Static** (only Static lights are
   baked), or rely on the Environment (a scene sky or a Custom Color) for an ambient occlusion
   bake.
4. Select the `BlenderLightmapGI` and press **Bake Lightmaps** in the 3D toolbar. The toolbar
   shows progress and an elapsed timer while it runs, and **Cancel** stops it. Each mesh lights
   up in the viewport as it finishes.
5. After baking, disable or hide the real time lights you baked, otherwise they double light the
   static geometry and wash out the result. You can keep them as fill if you want that look.

The first time you bake a node, a dialog asks where to save the `.lmbake`, defaulting next to
the scene. Later bakes reuse that path without asking.

Your materials take part in the bake, so a colored surface casts colored bounce light (a red
wall tints nearby geometry red) and emissive materials add light to the scene.

## Settings

All settings live on the `BlenderLightmapGI` node.

| Setting | What it does |
|---|---|
| `Texel Scale` | Lightmap resolution across the scene. Higher means sharper lightmaps and more texture memory. Tune it to your scene's scale. |
| `Max Texture Size` | The largest a single lightmap texture can get. Bigger scenes simply use more textures. |
| `Quality` | Low, Medium, High or Ultra. Higher is cleaner but slower to bake. |
| `Bounces` | How many times light bounces. Higher gives richer indirect light but bakes slower. 0 is direct light only. |
| `Use Denoiser` | Cleans up noise in the bake. Leave it on unless you want to see the raw result. |
| `Environment Mode` | Where ambient and sky light come from: Disabled, Scene (your `WorldEnvironment`), Custom Sky, or Custom Color. |
| `Custom Sky`, `Custom Color`, `Custom Energy` | The sky or color used by the Custom Sky and Custom Color modes. |
| `use_gpu` | Bake on the GPU (much faster) or fall back to the CPU. On by default. Turn it off if GPU baking is unstable on your machine or you want the steadiest result. |
| `bake_margin` | How far the bake bleeds past each UV island, in pixels. Raise it if you see dark seams between surfaces. |
| `indirect_clamp` | Removes fireflies, the stray bright speckles you can get in noisy interior bakes. 0 is off, try around 10. |
| `compress_lightmaps` | Trades a little quality for roughly 4x less GPU memory. Off by default. |

## Scripting

You can trigger a bake from an editor tool script, which is handy for automating it. It runs in
the editor only.

```gdscript
@tool
extends EditorScript  # run with File > Run in the script editor

func _run() -> void:
    var root := EditorInterface.get_edited_scene_root()
    var lm: BlenderLightmapGI = root.find_child("BlenderLightmapGI", true, false)
    var blender: String = ProjectSettings.get_setting("pavlaka/blender_path", "")
    # save_path is the .lmbake. The lightmap textures are written beside it.
    var err: int = await PavlakaBaker.bake(
        root, lm, blender,
        "res://lightmaps/%s.lmbake" % root.name,
        lm.get_bake_opts())          # the node's settings, omit for defaults
    print("bake result: ", err)      # OK (0), or an error code (ERR_SKIP if cancelled)
```

`PavlakaBaker.bake(root, lm, blender_path, save_path, opts := {}, cancelled := [])` returns `OK`
or an error code. To cancel, pass a one element array and set `cancelled[0] = true` from
elsewhere.
