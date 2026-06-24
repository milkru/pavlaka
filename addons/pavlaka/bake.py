"""Bake a Godot-exported scene's lightmaps (multi-mesh, one slice per mesh).

Imports a glb from Godot, finds every lightmap target (mesh with >=2 UV layers = it
carries a Godot UV2), and bakes IRRADIANCE (Diffuse, Direct+Indirect, Color OFF) into
each target's UV2. Each mesh -> its own denoised linear EXR slice (baked_<i>.exr).
Godot combines the per-mesh slices into one layered atlas via set_lightmap_textures([...]).

  blender --background --python bake.py -- <glb> <out_dir> [atlas sun_energy ambient samples amb_r amb_g amb_b]

The plugin runs this non-blocking and can't read stdout, so everything is mirrored to
<out_dir>/bake.log and the whole run is wrapped so a fatal error still writes baked.json.
"""
import bpy
import sys
import os
import json
import traceback

argv = sys.argv
rest = argv[argv.index("--") + 1:] if "--" in argv else []
glb = rest[0]
out_dir = rest[1] if len(rest) > 1 else os.path.dirname(glb)
os.makedirs(out_dir, exist_ok=True)

ATLAS = int(rest[2]) if len(rest) > 2 else 512
SUN_ENERGY = float(rest[3]) if len(rest) > 3 else 4.0
AMBIENT = float(rest[4]) if len(rest) > 4 else 0.2
SAMPLES = int(rest[5]) if len(rest) > 5 else 256
AMBIENT_RGB = (
    float(rest[6]) if len(rest) > 6 else 1.0,
    float(rest[7]) if len(rest) > 7 else 1.0,
    float(rest[8]) if len(rest) > 8 else 1.0,
)

_log = open(os.path.join(out_dir, "bake.log"), "w", encoding="utf-8")


def out(msg):
    print(msg)
    try:
        _log.write(str(msg) + "\n")
        _log.flush()
    except Exception:
        pass


def write_meta(meshes_meta, errors):
    meta = {
        "atlas": {"width": ATLAS, "height": ATLAS, "slices": len(meshes_meta)},
        "baked_exposure": 1.0,
        "meshes": meshes_meta,
        "errors": errors,
    }
    with open(os.path.join(out_dir, "baked.json"), "w") as f:
        json.dump(meta, f, indent=2)


def denoise_over(image, out_path):
    """Compositor OIDN denoise -> linear EXR at out_path (overwrites)."""
    sc = bpy.context.scene
    sc.use_nodes = True
    nt = sc.node_tree
    nt.nodes.clear()
    n_img = nt.nodes.new("CompositorNodeImage"); n_img.image = image
    n_dn = nt.nodes.new("CompositorNodeDenoise")
    n_out = nt.nodes.new("CompositorNodeComposite")
    nt.links.new(n_img.outputs["Image"], n_dn.inputs["Image"])
    nt.links.new(n_dn.outputs["Image"], n_out.inputs["Image"])
    sc.render.resolution_x = ATLAS
    sc.render.resolution_y = ATLAS
    sc.render.resolution_percentage = 100
    sc.cycles.samples = 1
    sc.frame_start = sc.frame_end = 1
    sc.frame_set(1)
    base = os.path.join(out_dir, "_dn")
    sc.render.filepath = base
    sc.render.image_settings.file_format = 'OPEN_EXR'
    sc.render.image_settings.color_depth = '32'
    bpy.ops.render.render(write_still=True)
    for produced in (base + ".exr", base + "0001.exr"):
        if os.path.exists(produced):
            if os.path.exists(out_path):
                os.remove(out_path)
            os.rename(produced, out_path)
            return True
    return False


def bake_one(scene, obj, slice_index):
    me = obj.data
    me.uv_layers.active_index = 1 if len(me.uv_layers) >= 2 else 0

    img = bpy.data.images.new("LM_%s" % obj.name, width=ATLAS, height=ATLAS,
                              float_buffer=True, is_data=True)
    mat = bpy.data.materials.new("BakeMat_%s" % obj.name)
    mat.use_nodes = True
    me.materials.clear()
    me.materials.append(mat)
    tex_node = mat.node_tree.nodes.new("ShaderNodeTexImage")
    tex_node.image = img
    for n in mat.node_tree.nodes:
        n.select = False
    tex_node.select = True
    mat.node_tree.nodes.active = tex_node

    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj

    scene.cycles.samples = SAMPLES
    out("PAVLAKA_BAKE: baking %s -> slice %d (uv_layers=%d, faces=%d)"
        % (obj.name, slice_index, len(me.uv_layers), len(me.polygons)))
    bpy.ops.object.bake(type='DIFFUSE', pass_filter={'DIRECT', 'INDIRECT'},
                        margin=16, use_clear=True)

    slice_path = os.path.join(out_dir, "baked_%d.exr" % slice_index)
    img.filepath_raw = slice_path
    img.file_format = 'OPEN_EXR'
    img.save()
    if denoise_over(img, slice_path):
        out("PAVLAKA_BAKE: denoised slice %d" % slice_index)
    return {
        "name": obj.name,
        "slice_index": slice_index,
        "uv_scale": [0.0, 0.0, 1.0, 1.0],  # full-0..1 UV2 -> identity remap
    }


def main():
    out("PAVLAKA_BAKE: Blender %s, glb=%s" % (".".join(map(str, bpy.app.version)), glb))
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=glb)

    scene = bpy.context.scene
    scene.render.engine = 'CYCLES'
    scene.cycles.device = 'CPU'
    scene.cycles.samples = SAMPLES
    scene.world = bpy.data.worlds.new("World")
    scene.world.use_nodes = True
    bg = scene.world.node_tree.nodes["Background"]
    # A new world's Background color defaults to near-black, so set a real color so
    # AMBIENT controls actual dome brightness (color * AMBIENT).
    bg.inputs[0].default_value = (AMBIENT_RGB[0], AMBIENT_RGB[1], AMBIENT_RGB[2], 1.0)
    bg.inputs[1].default_value = AMBIENT

    for obj in bpy.data.objects:
        if obj.type == 'LIGHT' and obj.data.type == 'SUN':
            obj.data.energy = SUN_ENERGY

    bake = scene.render.bake
    bake.use_pass_direct = True
    bake.use_pass_indirect = True
    bake.use_pass_color = False        # irradiance, not radiance
    bake.margin = 16
    bake.margin_type = 'EXTEND'
    bake.use_clear = True

    targets = [o for o in bpy.data.objects
               if o.type == 'MESH' and len(o.data.uv_layers) >= 2]
    targets.sort(key=lambda o: o.name)  # stable slice order
    out("PAVLAKA_BAKE: lightmap targets = %s" % [o.name for o in targets])

    meshes_meta = []
    errors = []
    for slice_index, obj in enumerate(targets):
        try:
            meshes_meta.append(bake_one(scene, obj, slice_index))
        except Exception as e:
            errors.append("%s: %s" % (obj.name, e))
            out("PAVLAKA_BAKE: ERROR baking %s:\n%s" % (obj.name, traceback.format_exc()))

    write_meta(meshes_meta, errors)
    out("PAVLAKA_BAKE: done (%d/%d slices, %d error(s))"
        % (len(meshes_meta), len(targets), len(errors)))


try:
    main()
except Exception as e:
    out("PAVLAKA_BAKE: FATAL: %s\n%s" % (e, traceback.format_exc()))
    try:
        write_meta([], ["fatal: %s" % e])
    except Exception:
        pass
finally:
    _log.close()
