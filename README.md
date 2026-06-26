# pavlaka

Bake Godot lightmaps externally in **Blender (Cycles)** and import them back as native
**`LightmapGIData`**. A Godot editor plugin that adds a `BlenderLightmapGI` node with a
"Bake Lightmaps" button, mirroring the built-in `LightmapGI` workflow.

Tested on **Godot 4.5 - 4.7** (developed on 4.7); other Godot 4.x versions probably work too,
they just haven't been tested. Engine internals are version specific, so long term
compatibility is not a goal. The Blender side uses the long stable bake API and works on
**Blender 4.x** (developed against 4.1.1).

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
- **GPU baking by default, CPU optional.** Bakes on the GPU for speed out of the box, and you
  can switch to the CPU for the most consistent results. (The built-in lightmapper is GPU-only.)
- **Scriptable.** A bake can be triggered from any editor tool script via
  `PavlakaBaker.bake(...)`, so you can batch-bake scenes or automate it.

## Requirements

- **Godot 4.x** (tested on 4.5 - 4.7)
- **Blender 4.x** (tested 4.1.1), reachable as an executable on disk
- Static meshes that have a **UV2** (lightmap) channel

## Install

1. Copy the `addons/pavlaka/` folder into your project's `addons/`.
2. **Project → Project Settings → Plugins** → enable **pavlaka**.
3. On enable it **auto-detects Blender** and sets **Project Settings → `pavlaka/blender_path`**.
   Only change it (Project Settings → search "pavlaka") if detection failed or you want a
   specific Blender version.

## Quick start

1. Add a **`BlenderLightmapGI`** node to a 3D scene.
2. Ensure your static meshes have a **UV2** (Import dock → Meshes → Light Baking =
   "Static Lightmaps" → Reimport).
3. Add a light with **Bake Mode = Static**.
4. Select the node and press **Bake Lightmaps** in the 3D toolbar.

See the **[Guide](docs/GUIDE.md)** for the full workflow, node parameters, scripting, and
limitations.

## Documentation

- **[Guide](docs/GUIDE.md)** — usage, node parameters, scripting, and limitations.
- **[RESEARCH.md](RESEARCH.md)** — design, Godot 4.7 source findings, the data contract, and
  the pitfalls discovered while building this.
