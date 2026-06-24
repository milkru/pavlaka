"""M2a — headless Cycles lightmap bake for the pavlaka POC.

Builds a tiny known scene (plane + cube occluder + sun), bakes IRRADIANCE into the
plane's UV (Diffuse, Direct+Indirect, Color OFF -> matches what Godot's lightmap
expects, see RESEARCH.md), and writes a linear EXR + a metadata JSON.

Run:
  blender --background --python blender/bake_poc.py -- <out_dir>

Output:
  <out_dir>/baked.exr   linear HDR irradiance atlas (one slice)
  <out_dir>/baked.json  metadata (mesh path, uv_scale, slice, baked_exposure)
"""

import bpy
import sys
import os
import json
import math

# ---- args after "--" -------------------------------------------------------
argv = sys.argv
out_dir = argv[argv.index("--") + 1] if "--" in argv else os.getcwd()
os.makedirs(out_dir, exist_ok=True)
ATLAS = 512

# ---- fresh empty scene -----------------------------------------------------
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.render.engine = 'CYCLES'
scene.cycles.device = 'CPU'        # safe & deterministic headless
scene.cycles.samples = 256
scene.world = bpy.data.worlds.new("World")
scene.world.use_nodes = True
# small constant sky so we get some ambient bounce (linear)
scene.world.node_tree.nodes["Background"].inputs[1].default_value = 0.2

# ---- geometry --------------------------------------------------------------
bpy.ops.mesh.primitive_plane_add(size=4.0, location=(0, 0, 0))
plane = bpy.context.active_object
plane.name = "Floor"

bpy.ops.mesh.primitive_cube_add(size=1.0, location=(0.4, 0.4, 0.7))
cube = bpy.context.active_object
cube.name = "Occluder"

# ---- sun (angled so the cube casts a clear shadow on the floor) ------------
sun_data = bpy.data.lights.new("Sun", 'SUN')
sun_data.energy = 3.0
sun = bpy.data.objects.new("Sun", sun_data)
scene.collection.objects.link(sun)
sun.rotation_euler = (math.radians(50), 0.0, math.radians(35))

# ---- bake target: image + material on the floor ---------------------------
img = bpy.data.images.new("Lightmap", width=ATLAS, height=ATLAS,
                          float_buffer=True, is_data=True)

mat = bpy.data.materials.new("FloorMat")
mat.use_nodes = True
plane.data.materials.append(mat)
tex_node = mat.node_tree.nodes.new("ShaderNodeTexImage")
tex_node.image = img
# the active image-texture node of the active object's active material is the bake target
for n in mat.node_tree.nodes:
    n.select = False
tex_node.select = True
mat.node_tree.nodes.active = tex_node

# give the cube a plain material too (so it participates in bounce/shadow)
cube_mat = bpy.data.materials.new("CubeMat")
cube_mat.use_nodes = True
cube.data.materials.append(cube_mat)

# ---- bake settings: IRRADIANCE (Color OFF) ---------------------------------
bake = scene.render.bake
bake.use_pass_direct = True
bake.use_pass_indirect = True
bake.use_pass_color = False        # <-- irradiance, not radiance
bake.margin = 16                   # dilation into the gutter (avoids seams)
bake.margin_type = 'EXTEND'
bake.use_clear = True

bpy.ops.object.select_all(action='DESELECT')
plane.select_set(True)
bpy.context.view_layer.objects.active = plane

print("PAVLAKA_BAKE: baking...")
bpy.ops.object.bake(type='DIFFUSE', pass_filter={'DIRECT', 'INDIRECT'},
                    margin=16, use_clear=True)

# ---- save linear EXR -------------------------------------------------------
exr_path = os.path.join(out_dir, "baked.exr")
img.filepath_raw = exr_path
img.file_format = 'OPEN_EXR'
img.save()
print("PAVLAKA_BAKE: wrote", exr_path)

# ---- metadata (single mesh, identity atlas placement) ----------------------
meta = {
    "atlas": {"width": ATLAS, "height": ATLAS, "slices": 1},
    "baked_exposure": 1.0,
    "meshes": [
        {"name": "Floor", "uv_scale": [0.0, 0.0, 1.0, 1.0], "slice_index": 0},
    ],
}
with open(os.path.join(out_dir, "baked.json"), "w") as f:
    json.dump(meta, f, indent=2)
print("PAVLAKA_BAKE: done")
