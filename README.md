# pavlaka

Bake Godot lightmaps externally in **Blender (Cycles)** and import them back as native
**`LightmapGIData`**. A Godot editor plugin that adds a `LightmapBlenderGI` node with a
"Bake with Blender" button, mirroring the built-in `LightmapGI` workflow.

Targets **Godot 4.7**. Engine internals are version specific, so long term compatibility
is not a goal. The Blender side uses the long stable bake API and works on **Blender 4.x**
(developed against 4.1.1).

## How it works

```
LightmapBlenderGI node + "Bake with Blender"
  -> export the scene's static meshes + lights to a temp glTF
  -> run Blender headless: Cycles bakes IRRADIANCE per mesh (Diffuse, Direct+Indirect,
     Color OFF), denoised, to one linear EXR slice per mesh
  -> import the slices as CompressedTexture2DArray
  -> assemble a native LightmapGIData (one combined layered atlas) and assign it
  -> save <scene>.lmbake; the scene renders with Godot's native LightmapGI runtime
```

Godot owns the UV2; Blender bakes into it. Each mesh gets its own atlas slice and Godot
combines them.

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

1. Add a **`LightmapBlenderGI`** node to your scene (Create Node dialog).
2. Make sure your static meshes have **UV2**. For imported meshes: Import dock →
   **Meshes → Light Baking = "Static Lightmaps"** → Reimport (Godot generates UV2 and
   marks them static). Meshes without UV2 are skipped.
3. Add at least one light and set its **Bake Mode = Static** (only Static lights are
   baked), or rely on the Environment (scene sky or Custom Color) for an ambient occlusion
   bake.
4. Select the `LightmapBlenderGI` and press **Bake with Blender** in the 3D toolbar.
   A progress dialog shows the stages; **Cancel** aborts the running bake.
5. After baking, **disable or hide the real time lights** you baked, otherwise they
   double light the static geometry and wash out the baked result. (Or keep them as fill.)

### Node parameters (`LightmapBlenderGI`)

| Group | Property | Meaning |
|---|---|---|
| Blender Bake | `output_dir` | Base dir for bake output (default `res://lightmaps`). Each bake writes to a per-scene subfolder mirroring the scene's path, so `res://levels/forest.tscn` goes to `res://lightmaps/levels/forest/` and same-named scenes in different folders never collide. Inside: one EXR per mesh named after the node, plus a `<scene>.lmbake`. |
| Blender Bake | `atlas_size` | Per-mesh lightmap slice resolution. |
| Tweaks | `Quality` | LightmapGI's own Quality dropdown (Low/Medium/High/Ultra), mapped to Cycles samples (64/128/256/512; denoised afterward). |
| Environment | `Mode` | LightmapGI's own Environment Mode, used for the bake's ambient and sky: **Disabled** (none), **Scene** (bake the scene's `WorldEnvironment` sky to a panorama), **Custom Sky** (bake a given `Sky`), **Custom Color** (flat color). |
| Environment | `Custom Sky` / `Custom Color` / `Custom Energy` | Used by the Custom Sky and Custom Color modes (energy scales either). |
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
- **One slice per mesh.** There is no space efficient atlas packing yet, and every mesh
  gets a full resolution slice regardless of size (Texture2DArray layers share dimensions).
- **Editor only, like the native bake.** Baking runs from the editor (it uses the editor
  filesystem to import the result), so it isn't a headless operation. Godot's own
  "Bake Lightmaps" works the same way.

See **[RESEARCH.md](RESEARCH.md)** for the design, the Godot 4.7 source findings, the
data contract, and the pitfalls discovered while building this.
