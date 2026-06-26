# pavlaka

Bake Godot lightmaps in **Blender (Cycles)** and bring them back as native
**`LightmapGIData`**. It is a Godot editor plugin that adds a `BlenderLightmapGI` node with a
**Bake Lightmaps** button, so the workflow feels just like the native `LightmapGI`.

Tested on **Godot 4.5 to 4.7** (built on 4.7). Other Godot 4.x versions probably work too, they
just have not been tested. The engine internals it leans on are version specific, so long term
compatibility is not a goal. The Blender side uses the long stable bake API and works on
**Blender 4.x** (built against 4.1.1).

![Example](https://github.com/milkru/data_resources/blob/main/pavlaka.png "Example")

## Why use this over the native LightmapGI?

- **Better looking bakes.** Cycles is a production path tracer, so the bounce light, soft
  shadows and ambient occlusion generally come out more accurate and natural than the native
  lightmapper.
- **It will not crash the editor.** The bake runs as a separate Blender process, so a bake that
  fails or misbehaves cannot take Godot down with it. The native lightmapper sometimes does.
- **Fewer light leaks.** In the scenes tested, Cycles leaks far less light through walls,
  corners and thin geometry than the native lightmapper.
- **Runs in the background.** The editor stays fully usable while a bake runs. The native bake
  locks the editor behind a modal progress dialog.
- **Cancel any time.** Press Cancel and the bake stops right away. The native one often ignores
  the cancel or only reacts after a long delay.
- **A single oversized mesh will not stop the bake.** If a mesh is too big to fit one page, its
  lightmap is scaled down to fit and a warning is logged, instead of the whole bake aborting the
  way the native one does.
- **GPU baking by default, CPU when you want it.** It bakes on the GPU out of the box for speed,
  and you can switch to the CPU for the most consistent result. The native lightmapper only runs
  on the GPU.
- **Live preview.** Each mesh lights up in the viewport the moment Blender finishes baking it,
  so you watch the scene come together instead of staring at a black box.
- **Scriptable.** You can start a bake from any editor tool script with `PavlakaBaker.bake(...)`,
  which makes batch baking and automation easy.

## Requirements

- **Godot 4.x** (tested on 4.5 to 4.7)
- **Blender 4.x** (tested 4.1.1), available as an executable on disk
- Static meshes with a **UV2** (lightmap) channel

## Install

1. Copy the `pavlaka` addon (the `addons/pavlaka` folder) into your project's `addons` folder.
2. Open **Project, Project Settings, Plugins** and enable **pavlaka**.
3. On enable it finds Blender automatically and fills in **Project Settings,
   `pavlaka/blender_path`**. You only need to touch that (search "pavlaka" in Project Settings)
   if detection failed or you want a specific Blender version.

## Quick start

The workflow is the same as the regular `LightmapGI`, just with a `BlenderLightmapGI` node.

1. Add a **`BlenderLightmapGI`** node to a 3D scene.
2. Make sure your static meshes have a **UV2** (Import dock, Meshes, Light Baking =
   "Static Lightmaps", then Reimport).
3. Add a light and set its **Bake Mode** to **Static**.
4. Select the node and press **Bake Lightmaps** in the 3D toolbar.

The **[Guide](docs/GUIDE.md)** covers the full workflow, the node parameters, scripting and the
known limitations.

## Acknowledgements

[Blender](https://www.blender.org) is a registered trademark of the Blender Foundation. pavlaka
is an independent tool that calls Blender as an external application. It is not affiliated with,
endorsed by, or sponsored by the Blender Foundation.
