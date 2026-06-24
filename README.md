# pavlaka

Bake Godot lightmaps externally in **Blender (Cycles)** and import them back as native
**`LightmapGIData`**. A Godot editor plugin that adds a `LightmapBlenderGI` node with a
"Bake with Blender" button, mirroring the built-in `LightmapGI` workflow.

Targets **Godot 4.7** (engine internals are version-specific; long-term compatibility is
not a goal). The Blender side uses the long-stable bake API and works on **Blender 4.x**
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
3. **Project Settings → search "pavlaka"** → set **`blender_path`** to your Blender
   executable (e.g. `C:/Program Files/Blender Foundation/Blender 4.1/blender.exe`).

## Usage

1. Add a **`LightmapBlenderGI`** node to your scene (Create Node dialog).
2. Make sure your static meshes have **UV2**. For imported meshes: Import dock →
   **Meshes → Light Baking = "Static Lightmaps"** → Reimport (Godot generates UV2 and
   marks them static). Meshes without UV2 are skipped.
3. Add at least one light (e.g. `DirectionalLight3D`), or rely on the ambient dome for a
   pure ambient-occlusion bake.
4. Select the `LightmapBlenderGI` and press **Bake with Blender** in the 3D toolbar.
   A progress dialog shows the stages; **Cancel** aborts the running bake.
5. After baking, **disable or hide the real-time lights** you baked, otherwise they
   double-light the static geometry and wash out the baked result. (Or keep them as fill.)

### Node parameters (`LightmapBlenderGI`)

| Group | Property | Meaning |
|---|---|---|
| Blender Bake | `output_dir` | Base dir for bake output (default `res://lightmaps`). Each bake writes to a per-scene subfolder mirroring the scene's path — e.g. `res://levels/forest.tscn` → `res://lightmaps/levels/forest/` — so same-named scenes in different folders never collide. Inside: one EXR per mesh named after the node + a `<scene>.lmbake`. |
| Blender Bake | `atlas_size` | Per-mesh lightmap slice resolution. |
| Blender Bake | `samples` | Cycles samples (denoised afterward). |
| Ambient Dome | `ambient_energy` | Sky/ambient dome brightness (white × energy). |
| Ambient Dome | `ambient_color` | Sky/ambient dome color. |
| Lights | `sun_energy` | Energy applied to sun lights during the bake. |

The inherited `LightmapGI` settings (Quality, Bounces, etc.) are hidden — baking is
controlled by the parameters above.

## Limitations / notes

- **Bake brightness isn't calibrated** to Godot's light units yet: sun lights use the
  fixed `sun_energy` rather than each light's own intensity.
- **Ambient** is a flat dome color, not your scene's `WorldEnvironment` sky.
- **One slice per mesh** — no space-efficient atlas packing yet (Texture2DArray layers
  share dimensions).
- Baking is a **GUI-editor** action (it relies on the editor filesystem to import the
  result), not a headless/CI operation.
- The button-hiding of the built-in "Bake Lightmaps" matches the English label.

See **[RESEARCH.md](RESEARCH.md)** for the design, the Godot 4.7 source findings, the
data contract, and the pitfalls discovered while building this.
