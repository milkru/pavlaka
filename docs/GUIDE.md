# `pavlaka` guide

This guide covers the full workflow, node settings, scripting, and a few things to watch out for. For the short overview and install steps, see the [README](../README.md).

## Baking a scene

The workflow is similar to the regular `LightmapGI`.

1. Add a `BlenderLightmapGI` node to your scene.
2. Make sure your static meshes have a **UV2** lightmap channel.
3. Add at least one light and set its **Bake Mode** to **Static**.
4. Select the `BlenderLightmapGI` node and press **Bake Lightmaps** in the 3D toolbar.
5. After baking, disable or hide the real-time lights you baked.

For imported meshes, open the Import dock, set **Meshes > Light Baking** to **Static Lightmaps**, then reimport. Meshes without UV2 are skipped.

Only lights with **Bake Mode** set to **Static** are baked. You can also bake ambient lighting from the environment, using a scene sky or a custom color.

While baking, the toolbar shows progress and elapsed time. **Cancel** stops the Blender process directly. Each mesh updates in the viewport when Blender finishes baking it.

The first time you bake a node, `pavlaka` asks where to save the `.lmbake` file. By default, it saves next to the scene. Later bakes reuse the same path without asking.

Your materials are included in the bake. Colored surfaces cast colored bounce light, and emissive materials add light to the scene.

## After baking

Disable or hide the real-time lights you baked. Otherwise, the static geometry will be lit twice: once by the baked lightmap, and once by the live light.

You can keep real-time lights enabled if you want them as extra fill, but the result will usually look brighter and flatter.

## Settings

All settings live on the `BlenderLightmapGI` node.

| Setting                                       | What it does                                                                                                                     |
| --------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `Texel Scale`                                 | Controls lightmap resolution across the scene. Higher values give sharper lightmaps but use more texture memory.                 |
| `Max Texture Size`                            | Sets the largest size of a single lightmap texture. Bigger scenes can still use more than one texture.                           |
| `Quality`                                     | Controls bake quality: Low, Medium, High, or Ultra. Higher values are cleaner but slower.                                        |
| `Bounces`                                     | Controls how many times light can bounce. Higher values give richer indirect light but bake slower. `0` means direct light only. |
| `Use Denoiser`                                | Cleans up noise in the bake. Leave it on unless you want to inspect the raw result.                                              |
| `Environment Mode`                            | Controls where ambient and sky light come from: Disabled, Scene, Custom Sky, or Custom Color.                                    |
| `Custom Sky`, `Custom Color`, `Custom Energy` | Settings used by the Custom Sky and Custom Color environment modes.                                                              |
| `use_gpu`                                     | Bakes on the GPU when enabled. Turn it off to bake on the CPU instead.                                                           |
| `bake_margin`                                 | Controls how far the bake bleeds past each UV island, in pixels. Increase it if you see dark seams.                              |
| `indirect_clamp`                              | Helps remove fireflies, which are bright speckles in noisy bakes. `0` disables it. Try around `10` if needed.                    |
| `compress_lightmaps`                          | Reduces GPU memory use by roughly 4x, with some quality loss. Off by default.                                                    |

## GPU and CPU baking

`pavlaka` uses GPU baking by default because it is usually much faster.

CPU baking is slower, but it can be useful if GPU baking is unstable on your machine or if you want the most consistent result across hardware.

## Oversized meshes

If a mesh is too large to fit one lightmap page, `pavlaka` scales that mesh's lightmap down to fit and logs a warning.

This lets the bake continue instead of failing the whole scene.

## Scripting

You can start a bake from an editor tool script. This is useful for batch baking or custom editor tools.

```gdscript
@tool
extends EditorScript

func _run() -> void:
    var root := EditorInterface.get_edited_scene_root()
    var lm: BlenderLightmapGI = root.find_child("BlenderLightmapGI", true, false)
    var blender: String = ProjectSettings.get_setting("pavlaka/blender_path", "")

    var err: int = await PavlakaBaker.bake(
        root,
        lm,
        blender,
        "res://lightmaps/%s.lmbake" % root.name,
        lm.get_bake_opts()
    )

    print("bake result: ", err)
```

`PavlakaBaker.bake(root, lm, blender_path, save_path, opts := {}, cancelled := [])` returns `OK` or an error code.

To cancel a scripted bake, pass a one-element array and set `cancelled[0] = true` from somewhere else.

## Things to watch out for

* Meshes without UV2 are skipped.
* Only Static lights are baked.
* Real-time lights should usually be disabled after baking.
* Very high `Texel Scale`, `Quality`, or `Bounces` values can make bakes much slower.
* `bake_margin` can help with seams, but it cannot fix bad UV2 unwraps.
* `compress_lightmaps` saves memory, but can slightly reduce quality.
