# pavlaka Guide

Full usage, node parameters, scripting, and limitations for the pavlaka lightmap baker.
For the overview, pros, requirements, and install steps, see the
[README](../README.md).

## How it works

```
BlenderLightmapGI node + "Bake Lightmaps"
  -> pack each mesh into atlas pages, sized by its world-space surface area
  -> export the scene's static meshes + lights to a temp glTF
  -> run Blender headless: Cycles bakes IRRADIANCE per mesh (Diffuse, Direct+Indirect,
     Color OFF), denoised, each at its packed chunk size
  -> stream each finished mesh into the viewport live (in-memory preview) as it bakes
  -> composite the per-mesh bakes into the atlas pages, import as CompressedTexture2DArray
  -> assemble a native LightmapGIData (pages as layers) and assign it
  -> save the .lmbake (next to the scene by default); renders with Godot's LightmapGI runtime
```

Godot owns the UV2; Blender bakes into it. Meshes are packed into one or more atlas pages
(area-proportional, like the native lightmapper), composited, and assigned as a single
`LightmapGIData`.

Each mesh's real material is carried across (its effective material, including
`material_override`), so indirect light is **colored by surface albedo** (a red wall casts
red bounce light) and **emissive materials cast light** into the bake. The target's own
albedo is divided out (Color OFF) and reapplied by Godot at runtime.

## Usage

1. Add a **`BlenderLightmapGI`** node to your scene (Create Node dialog).
2. Make sure your static meshes have **UV2**. For imported meshes: Import dock →
   **Meshes → Light Baking = "Static Lightmaps"** → Reimport (Godot generates UV2 and
   marks them static). Meshes without UV2 are skipped.
3. Add at least one light and set its **Bake Mode = Static** (only Static lights are
   baked), or rely on the Environment (scene sky or Custom Color) for an ambient occlusion
   bake.
4. Select the `BlenderLightmapGI` and press **Bake with Blender** in the 3D toolbar.
   A progress dialog shows the stages; **Cancel** aborts the running bake.
5. After baking, **disable or hide the real time lights** you baked, otherwise they
   double light the static geometry and wash out the baked result. (Or keep them as fill.)

On the first bake of a node a dialog asks where to save the `.lmbake` (defaulting next to
the scene); subsequent bakes reuse that path silently, like the native lightmapper.

## Node parameters (`BlenderLightmapGI`)

| Group | Property | Meaning |
|---|---|---|
| Tweaks | `Texel Scale` | LightmapGI's own density multiplier. Each mesh's lightmap chunk is sized `sqrt(world surface area) × 10 × texel_scale`, so density is uniform across the scene (no stretching). Higher = sharper / more texels / more pages. Tune to your scene's scale. |
| Tweaks | `Max Texture Size` | LightmapGI's own cap on each atlas page's dimensions. Pages grow to fit their content but never exceed this in either dimension, opening a new page when they would (multi-page, like the native lightmapper). A mesh whose chunk can't fit one page is shrunk to fit and a warning is logged. |
| Tweaks | `Quality` | LightmapGI's own Quality dropdown (Low/Medium/High/Ultra), mapped to Cycles samples (64/128/256/512; denoised afterward). |
| Tweaks | `Bounces` | LightmapGI's own bounce count, used as Cycles' diffuse bounces. Higher fills in indirect light more accurately (brighter, softer GI) but bakes slower. 0 = direct light only. |
| Tweaks | `Use Denoiser` | LightmapGI's own denoiser toggle, used to run OIDN denoising on each baked page (recommended; low sample counts are noisy). Off only to inspect the raw bake. |
| Environment | `Mode` | LightmapGI's own Environment Mode, used for the bake's ambient and sky: **Disabled** (none), **Scene** (bake the scene's `WorldEnvironment` sky to a panorama), **Custom Sky** (bake a given `Sky`), **Custom Color** (flat color). |
| Environment | `Custom Sky` / `Custom Color` / `Custom Energy` | Used by the Custom Sky and Custom Color modes (energy scales either). |
| Blender Bake | `use_gpu` | Render the bake on the GPU if a compute device is available (much faster), else fall back to CPU. **On by default.** Turn off if GPU baking is unstable on your machine or you want the most CPU-consistent result. |
| Blender Bake | `bake_margin` | Pixels the baked result is dilated past each UV island edge. Higher reduces dark seams / bleeding between charts; too low can show black edges. |
| Blender Bake | `indirect_clamp` | Clamp the brightness of individual indirect light samples to kill fireflies (bright speckle noise the denoiser can't fully remove). `0` = off. A small value like `10` cleans up noisy interior bakes at a tiny cost in indirect brightness. |
| Blender Bake | `compress_lightmaps` | Compress the baked lightmap textures (VRAM compression, ~4× smaller GPU memory). **Off** (default): lossless, pages kept at their exact content-fit size. **On**: ~4× smaller VRAM, but textures are rounded up to a power of two (some wasted space, a page may exceed Max Texture Size) and BC6H can band slightly on HDR. |

The other inherited `LightmapGI` settings (Bias, Gen Probes, etc.) are hidden, since baking
is controlled by the parameters above.

## Scripting

The bake is a static coroutine on the global `PavlakaBaker` class, so any editor tool script
can trigger it directly (this is what the "Bake Lightmaps" button does under the hood). It
runs in the editor only (it uses the editor filesystem to import the result).

```gdscript
@tool
extends EditorScript  # run with File > Run in the script editor

func _run() -> void:
    var root := EditorInterface.get_edited_scene_root()
    var lm: BlenderLightmapGI = root.find_child("BlenderLightmapGI", true, false)
    var blender: String = ProjectSettings.get_setting("pavlaka/blender_path", "")
    # save_path is the .lmbake; the page EXRs are written beside it
    var err: int = await PavlakaBaker.bake(
        root, lm, blender,
        "res://lightmaps/%s.lmbake" % root.name,
        lm.get_bake_opts())          # all the node's tweaks; omit for defaults
    print("bake result: ", err)      # OK (0), or ERR_* / ERR_SKIP if cancelled
```

`PavlakaBaker.bake(root, lm, blender_path, save_path, opts := {}, cancelled := [])` returns
`OK` or an error code. To cancel, pass a one-element array and set `cancelled[0] = true` from
elsewhere. Calling it directly skips the plugin's UI (save dialog, progress strip), so it's
ideal for automation, e.g. batch-baking every node in the scene:

```gdscript
for lm in root.find_children("*", "BlenderLightmapGI", true, false):
    await PavlakaBaker.bake(root, lm, blender, "res://lightmaps/%s.lmbake" % lm.name, lm.get_bake_opts())
```

Bake sequentially (await each one) — don't run two at once into the same output folder.

## Limitations / notes

- **Point/spot brightness differs from Godot.** Every light's energy is converted with the
  exact `π` factor that bridges Godot's energy convention to Cycles' irradiance bake, so
  **directional** lights match Godot automatically. **Point and spot** carry the same
  converted energy but render with Cycles' physical inverse-square falloff (vs Godot's
  range-based one) — an intentional lighting-model difference, not something the plugin
  corrects. Adjust the light's own energy in Godot if you need it brighter or dimmer.
- **Very large meshes get shrunk, not split.** A mesh whose lightmap chunk can't fit one
  `Max Texture Size` page is scaled down to fit (lower density there) and a warning names it.
  Unlike the native lightmapper this never aborts the bake, but for best quality split the
  mesh, raise `Max Texture Size`, or lower `Texel Scale`.
