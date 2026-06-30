# pavlaka

`pavlaka` bakes Godot lightmaps in **Blender (Cycles)** and imports them back as native **`LightmapGIData`**.

It is a Godot editor plugin that adds a `BlenderLightmapGI` node with a **Bake Lightmaps** button, so the workflow feels close to the native `LightmapGI`.

![Example](https://github.com/milkru/data_resources/blob/main/pavlaka.png "Example")

## Why use this over native LightmapGI?

* **Better looking bakes**
  Cycles is a production path tracer, so bounce light, soft shadows, and ambient occlusion usually look more natural.

* **Fewer light leaks**
  In tested scenes, Cycles leaks less light through walls, corners, and thin geometry than the native lightmapper.

* **Safer baking**
  The bake runs in a separate Blender process. If something fails, it should not crash the Godot editor.

* **Background baking**
  The editor stays usable while Blender bakes the lightmaps.

* **Live preview**
  Meshes update in the viewport as they finish baking, so you can watch the scene come together.

* **Scriptable**
  Bakes can be started from editor scripts with `PavlakaBaker.bake(...)`, which makes batch baking and automation easier.

## Requirements

* **Godot 4.x**
  Tested with Godot 4.5 to 4.7, built on 4.7. Other Godot 4.x versions may work, but they have not been tested.

* **Blender 4.x or 5.x**
  Tested with Blender 4.1.1 and 5.1.2. Blender needs to be available as an executable on disk.

* Static meshes with a **UV2** lightmap channel.

## Install

1. Copy `addons/pavlaka` into your project's `addons` folder.
2. Open **Project > Project Settings > Plugins** and enable **pavlaka**.
3. When enabled, `pavlaka` tries to find Blender automatically and writes the path to **Project Settings > `pavlaka/blender_path`**.

You only need to change `pavlaka/blender_path` if detection fails or if you want to use a specific Blender version.

## Quick start

The workflow is similar to the regular `LightmapGI`, but you use a `BlenderLightmapGI` node instead.

1. Add a `BlenderLightmapGI` node to a 3D scene.
2. Make sure your static meshes have a **UV2** channel.
3. Add a light and set its **Bake Mode** to **Static**.
4. Select the `BlenderLightmapGI` node and press **Bake Lightmaps** in the 3D toolbar.

See [docs/GUIDE.md](docs/GUIDE.md) for the full workflow, settings, scripting, and things to watch out for.

## Acknowledgements

[Blender](https://www.blender.org) is a registered trademark of the Blender Foundation.

`pavlaka` is an independent tool that calls Blender as an external application. It is not affiliated with, endorsed by, or sponsored by the Blender Foundation.
