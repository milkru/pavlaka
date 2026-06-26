# pavlaka

Bake Godot lightmaps externally in **Blender (Cycles)** and import them back as native
**`LightmapGIData`**. A Godot editor plugin that adds a `BlenderLightmapGI` node with a
"Bake with Blender" button, mirroring the built-in `LightmapGI` workflow.

Targets **Godot 4.7**. Engine internals are version specific, so long term compatibility
is not a goal. The Blender side uses the long stable bake API and works on **Blender 4.x**
(developed against 4.1.1).

## Why use this over the built-in LightmapGI?

- **It can't crash the editor.** The bake runs in a separate Blender process, so a failed or
  misbehaving bake can't take Godot down with it (the built-in lightmapper sometimes does).
- **Fewer light leaks.** Cycles' path-traced bake leaks noticeably less light through walls,
  corners and thin geometry than the built-in lightmapper in the scenes tested.
- **Non-blocking.** Baking happens in the background and the editor stays fully usable while
  it runs. The built-in bake blocks the editor behind a modal progress dialog.
- **It never hard-fails on a too-big mesh.** A mesh whose lightmap can't fit one page is
  shrunk to fit (with a warning) instead of aborting the whole bake, which the built-in
  lightmapper does.
- **Optional GPU baking.** Bake on the GPU for a big speed-up, or on the CPU for the most
  consistent results. (See the note below: the built-in lightmapper is GPU-only.)
- **Scriptable.** A bake can be triggered from any editor tool script via
  `PavlakaBaker.bake(...)`, so you can batch-bake scenes or automate it.

## How it works

```
BlenderLightmapGI node + "Bake Lightmaps"
  -> pack each mesh into atlas pages, sized by its world-space surface area
  -> export the scene's static meshes + lights to a temp glTF
  -> run Blender headless: Cycles bakes IRRADIANCE per mesh (Diffuse, Direct+Indirect,
     Color OFF), denoised, each at its packed chunk size
  -> composite the per-mesh bakes into the atlas pages, import as CompressedTexture2DArray
  -> assemble a native LightmapGIData (pages as layers) and assign it
  -> save the .lmbake (next to the scene by default); renders with Godot's LightmapGI runtime
```

Godot owns the UV2; Blender bakes into it. Meshes are packed into one or more atlas pages
(area-proportional, like the native lightmapper), composited, and assigned as a single
`LightmapGIData`.

## Requirements

- **Godot 4.7**
- **Blender 4.x** (tested 4.1.1), reachable as an executable on disk
- Static meshes that have a **UV2** (lightmap) channel

## Install

1. Copy the `addons/pavlaka/` folder into your project's `addons/`.
2. **Project → Project Settings → Plugins** → enable **pavlaka**.
3. On enable it **auto-detects Blender** and sets **Project Settings → `pavlaka/blender_path`**.
   Only change it (Project Settings → search "pavlaka") if detection failed or you want a
   specific Blender version.

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

### Node parameters (`BlenderLightmapGI`)

| Group | Property | Meaning |
|---|---|---|
| Tweaks | `Texel Scale` | LightmapGI's own density multiplier. Each mesh's lightmap chunk is sized `sqrt(world surface area) × 10 × texel_scale`, so density is uniform across the scene (no stretching). Higher = sharper / more texels / more pages. Tune to your scene's scale. |
| Tweaks | `Max Texture Size` | LightmapGI's own cap on each atlas page's dimensions. Pages grow to fit their content but never exceed this in either dimension, opening a new page when they would (multi-page, like the native lightmapper). A mesh whose chunk can't fit one page is shrunk to fit and a warning is logged. |
| Tweaks | `Quality` | LightmapGI's own Quality dropdown (Low/Medium/High/Ultra), mapped to Cycles samples (64/128/256/512; denoised afterward). |
| Tweaks | `Bounces` | LightmapGI's own bounce count, used as Cycles' diffuse bounces. Higher fills in indirect light more accurately (brighter, softer GI) but bakes slower. 0 = direct light only. |
| Blender Bake | `use_gpu` | Render the bake on the GPU if a compute device is available (much faster), else fall back to CPU. Turn off if GPU baking is unstable on your machine. |
| Blender Bake | `bake_margin` | Pixels the baked result is dilated past each UV island edge. Higher reduces dark seams / bleeding between charts; too low can show black edges. |
| Tweaks | `Use Denoiser` | LightmapGI's own denoiser toggle, used to run OIDN denoising on each baked page (recommended; low sample counts are noisy). Off only to inspect the raw bake. |
| Environment | `Mode` | LightmapGI's own Environment Mode, used for the bake's ambient and sky: **Disabled** (none), **Scene** (bake the scene's `WorldEnvironment` sky to a panorama), **Custom Sky** (bake a given `Sky`), **Custom Color** (flat color). |
| Environment | `Custom Sky` / `Custom Color` / `Custom Energy` | Used by the Custom Sky and Custom Color modes (energy scales either). |
| Blender Bake | `compress_lightmaps` | Compress the baked lightmap textures (VRAM compression, ~4× smaller GPU memory). **Off** (default): lossless, pages kept at their exact content-fit size. **On**: ~4× smaller VRAM, but textures are rounded up to a power of two (some wasted space, a page may exceed Max Texture Size) and BC6H can band slightly on HDR. |
| Lights | `light_energy_scale` | Multiplier on each **Static** light's own energy and color during the bake (only `Bake Mode = Static` lights contribute). Tune if baked brightness doesn't match the in-editor lighting. |

The inherited `LightmapGI` settings (Quality, Bounces, etc.) are hidden. Baking is
controlled by the parameters above.

## Limitations / notes

- **Brightness matching isn't automatic.** Each Static light's real energy and color is
  used, but Godot's energy is dimensionless while Cycles uses physical units, so absolute
  brightness may not match the viewport. Tune `light_energy_scale`. **Point and spot**
  lights match least well, because Cycles' inverse square falloff differs from Godot's
  model; directional lights are the well behaved case.
- **Sky rotation isn't applied.** A baked `WorldEnvironment` sky ignores Godot's
  `sky_rotation` (negligible for low frequency ambient and AO; get direct sun from a
  Static `DirectionalLight3D`, not the sky).
- **Very large meshes get shrunk, not split.** A mesh whose lightmap chunk can't fit one
  `Max Texture Size` page is scaled down to fit (lower density there) and a warning names it.
  Unlike the native lightmapper this never aborts the bake, but for best quality split the
  mesh, raise `Max Texture Size`, or lower `Texel Scale`.

See **[RESEARCH.md](RESEARCH.md)** for the design, the Godot 4.7 source findings, the
data contract, and the pitfalls discovered while building this.
