# pavlaka Guide

Usage, node parameters, scripting and limitations for the pavlaka lightmap baker. For the
overview, the reasons to use it, requirements and install steps, see the [README](../README.md).

## How it works

```
BlenderLightmapGI node + "Bake Lightmaps"
  -> pack each mesh into atlas pages, sized by its world space surface area
  -> export the scene's static meshes and lights to a temp glTF
  -> run Blender headless: Cycles bakes IRRADIANCE per mesh (Diffuse, Direct+Indirect,
     Color OFF), denoised, each at its packed chunk size
  -> stream each finished mesh into the viewport live (in memory preview) as it bakes
  -> composite the per mesh bakes into the atlas pages, import as CompressedTexture2DArray
  -> assemble a native LightmapGIData (pages as layers) and assign it
  -> save the .lmbake (next to the scene by default), then it renders with Godot's LightmapGI
```

Godot owns the UV2 and Blender bakes into it. Meshes are packed into one or more atlas pages,
each mesh getting a share proportional to its world space surface area the way the native
lightmapper does, then composited and assigned as a single `LightmapGIData`.

Each mesh's real material comes along for the bake, including any `material_override`, so
indirect light is **colored by surface albedo** (a red wall casts red bounce light) and
**emissive materials cast light** into the scene. The target's own albedo is divided out
(Color OFF) and reapplied by Godot at runtime.

## Usage

1. Add a **`BlenderLightmapGI`** node to your scene (Create Node dialog).
2. Make sure your static meshes have a **UV2**. For imported meshes, go to the Import dock, set
   **Meshes, Light Baking** to **Static Lightmaps**, then Reimport. Godot generates the UV2 and
   marks the meshes static. Meshes without a UV2 are skipped.
3. Add at least one light and set its **Bake Mode** to **Static** (only Static lights are baked),
   or rely on the Environment (scene sky or Custom Color) for an ambient occlusion bake.
4. Select the `BlenderLightmapGI` and press **Bake Lightmaps** in the 3D toolbar. The toolbar
   shows progress and an elapsed timer, and **Cancel** stops a running bake.
5. After baking, disable or hide the real time lights you baked, otherwise they double light the
   static geometry and wash out the result. You can also keep them as fill if that is the look
   you want.

The first time you bake a node, a dialog asks where to save the `.lmbake`, defaulting next to
the scene. Later bakes reuse that path without asking, the same way the native lightmapper does.

## Node parameters (`BlenderLightmapGI`)

| Group | Property | Meaning |
|---|---|---|
| Tweaks | `Texel Scale` | LightmapGI's own density multiplier. Each mesh's lightmap chunk is sized `sqrt(world surface area) × 10 × texel_scale`, so density stays uniform across the scene with no stretching. Higher means sharper, more texels and more pages. Tune it to your scene's scale. |
| Tweaks | `Max Texture Size` | LightmapGI's own cap on each atlas page's dimensions. Pages grow to fit their content but never go past this in either dimension, opening a new page when they would, the way the native lightmapper does. A mesh whose chunk cannot fit one page is shrunk to fit and a warning is logged. |
| Tweaks | `Quality` | LightmapGI's own Quality dropdown (Low, Medium, High, Ultra), mapped to Cycles samples (64, 128, 256, 512), denoised afterward. |
| Tweaks | `Bounces` | LightmapGI's own bounce count, used as Cycles' diffuse bounces. Higher fills in indirect light more accurately for brighter, softer GI, but bakes slower. 0 is direct light only. |
| Tweaks | `Use Denoiser` | LightmapGI's own denoiser toggle, used to run OIDN denoising on each baked page. Recommended, since low sample counts are noisy. Turn it off only to inspect the raw bake. |
| Environment | `Mode` | LightmapGI's own Environment Mode, used for the bake's ambient and sky. **Disabled** (none), **Scene** (bake the scene's `WorldEnvironment` sky to a panorama), **Custom Sky** (bake a given `Sky`), **Custom Color** (flat color). |
| Environment | `Custom Sky`, `Custom Color`, `Custom Energy` | Used by the Custom Sky and Custom Color modes. Energy scales either one. |
| Blender Bake | `use_gpu` | Render the bake on the GPU if a compute device is available (much faster), otherwise fall back to the CPU. **On by default.** Turn it off if GPU baking is unstable on your machine or you want the most CPU consistent result. |
| Blender Bake | `bake_margin` | How many pixels the baked result is dilated past each UV island edge. Higher cuts down on dark seams and bleeding between charts. Too low can show black edges. |
| Blender Bake | `indirect_clamp` | Clamp the brightness of individual indirect light samples to kill fireflies, the bright speckles the denoiser cannot fully remove. `0` is off. A small value like `10` cleans up noisy interior bakes at a tiny cost in indirect brightness. |
| Blender Bake | `compress_lightmaps` | Compress the baked lightmap textures with VRAM compression for about 4x smaller GPU memory. **Off** (default) keeps the pages lossless at their exact content fit size. **On** is about 4x smaller, but textures round up to a power of two (some wasted space, and a page can go past Max Texture Size) and BC6H can band slightly on HDR. |

The other inherited `LightmapGI` settings (Bias, Gen Probes and so on) are hidden, since the
parameters above drive the bake.

## Scripting

The bake is a static coroutine on the global `PavlakaBaker` class, so any editor tool script can
trigger it directly. This is exactly what the Bake Lightmaps button does under the hood. It runs
in the editor only, since it uses the editor filesystem to import the result.

```gdscript
@tool
extends EditorScript  # run with File > Run in the script editor

func _run() -> void:
    var root := EditorInterface.get_edited_scene_root()
    var lm: BlenderLightmapGI = root.find_child("BlenderLightmapGI", true, false)
    var blender: String = ProjectSettings.get_setting("pavlaka/blender_path", "")
    # save_path is the .lmbake. The page EXRs are written beside it.
    var err: int = await PavlakaBaker.bake(
        root, lm, blender,
        "res://lightmaps/%s.lmbake" % root.name,
        lm.get_bake_opts())          # all the node's tweaks, omit for defaults
    print("bake result: ", err)      # OK (0), or ERR_* / ERR_SKIP if cancelled
```

`PavlakaBaker.bake(root, lm, blender_path, save_path, opts := {}, cancelled := [])` returns `OK`
or an error code. To cancel, pass a one element array and set `cancelled[0] = true` from
elsewhere. Calling it directly skips the plugin's UI (the save dialog and progress strip), which
makes it a good fit for automation. For example, to bake every node in the scene:

```gdscript
for lm in root.find_children("*", "BlenderLightmapGI", true, false):
    await PavlakaBaker.bake(root, lm, blender, "res://lightmaps/%s.lmbake" % lm.name, lm.get_bake_opts())
```

Bake them one at a time (await each call). Do not run two at once into the same output folder.

## Limitations and notes

- **Point and spot brightness differs from Godot.** Every light's energy is converted with the
  exact `π` factor that bridges Godot's energy convention to Cycles' irradiance bake, so
  **directional** lights match Godot automatically. **Point and spot** lights carry the same
  converted energy but render with Cycles' physical inverse square falloff rather than Godot's
  range based one. That is a real lighting model difference, not something the plugin tries to
  hide. If you want one brighter or dimmer, change that light's energy in Godot.
- **A very large mesh is shrunk, not split.** A mesh whose lightmap chunk cannot fit one
  `Max Texture Size` page is scaled down to fit, with lower density there, and a warning names
  it. Unlike the native lightmapper this never aborts the bake. For the best quality, split the
  mesh, raise `Max Texture Size`, or lower `Texel Scale`.
