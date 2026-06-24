"""Transport de-risk: import a glb and report each mesh's UV layers + a sample UV2.
  blender --background --python blender/inspect_gltf.py -- <glb_path>
"""
import bpy
import sys

argv = sys.argv
glb = argv[argv.index("--") + 1]

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=glb)

for obj in bpy.data.objects:
    if obj.type != 'MESH':
        continue
    me = obj.data
    names = [uv.name for uv in me.uv_layers]
    print("INSPECT: mesh=%s uv_layers=%d names=%s" % (obj.name, len(me.uv_layers), names))
    # sample the value of each UV layer at loop 0
    for uv in me.uv_layers:
        if len(uv.data) > 0:
            v = uv.data[0].uv
            print("INSPECT:   layer '%s' loop0=(%.3f, %.3f)" % (uv.name, v[0], v[1]))
