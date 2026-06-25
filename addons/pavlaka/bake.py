"""Bake a Godot-exported scene's lightmaps (multi-mesh).

Imports a glb from Godot, finds every lightmap target (mesh with >=2 UV layers = it
carries a Godot UV2), and bakes IRRADIANCE (Diffuse, Direct+Indirect, Color OFF) into
each target's UV2. Each mesh -> its own denoised linear EXR named after the node, sized
to the per-mesh chunk size Godot computed from world-space surface area (params "sizes").
Godot then composites these into one packed lightmap atlas.

  blender --background --python bake.py -- <glb> <out_dir> <params.json>

The plugin runs this non-blocking and can't read stdout, so everything is mirrored to
<out_dir>/bake.log and the whole run is wrapped so a fatal error still writes baked.json.
"""
import bpy
import sys
import os
import re
import json
import traceback

argv = sys.argv
rest = argv[argv.index("--") + 1:] if "--" in argv else []
glb = rest[0]
out_dir = rest[1] if len(rest) > 1 else os.path.dirname(glb)
os.makedirs(out_dir, exist_ok=True)

# bake parameters come from a JSON file written by the plugin
with open(rest[2], "r") as _pf:
    PARAMS = json.load(_pf)
# per-mesh chunk size (px), keyed by node name; Godot computed these from world area
SIZES = PARAMS.get("sizes", {})
DEFAULT_SIZE = 512
SAMPLES = int(PARAMS.get("samples", 256))
AMBIENT = float(PARAMS.get("ambient_energy", 0.2))
AMBIENT_RGB = PARAMS.get("ambient_color", [1.0, 1.0, 1.0])
LIGHT_ENERGY_SCALE = float(PARAMS.get("light_energy_scale", 1.0))
# name -> {"energy", "color":[r,g,b] linear}; used to override imported lights
LIGHTS = {l["name"]: l for l in PARAMS.get("lights", [])}

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
        "baked_exposure": 1.0,
        "meshes": meshes_meta,
        "errors": errors,
    }
    with open(os.path.join(out_dir, "baked.json"), "w") as f:
        json.dump(meta, f, indent=2)


def denoise_over(image, out_path, size):
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
    sc.render.resolution_x = size
    sc.render.resolution_y = size
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


def bake_one(scene, obj, slice_path, size):
    me = obj.data
    me.uv_layers.active_index = 1 if len(me.uv_layers) >= 2 else 0

    img = bpy.data.images.new("LM_%s" % obj.name, width=size, height=size,
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
    bpy.ops.object.bake(type='DIFFUSE', pass_filter={'DIRECT', 'INDIRECT'},
                        margin=16, use_clear=True)

    img.filepath_raw = slice_path
    img.file_format = 'OPEN_EXR'
    img.save()
    denoise_over(img, slice_path, size)


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
    wnt = scene.world.node_tree
    bg = wnt.nodes["Background"]
    sky = PARAMS.get("sky_panorama", "")
    if sky and os.path.exists(sky):
        # use the scene's baked WorldEnvironment sky as an equirect world texture
        env_tex = wnt.nodes.new("ShaderNodeTexEnvironment")
        env_tex.image = bpy.data.images.load(sky)
        wnt.links.new(env_tex.outputs["Color"], bg.inputs[0])
        bg.inputs[1].default_value = 1.0
    else:
        # flat ambient dome (a new world's Background color defaults to near-black, so
        # set a real color and let AMBIENT control dome brightness)
        bg.inputs[0].default_value = (AMBIENT_RGB[0], AMBIENT_RGB[1], AMBIENT_RGB[2], 1.0)
        bg.inputs[1].default_value = AMBIENT

    # override imported lights with the Godot light's actual energy (x scale) and color
    for obj in bpy.data.objects:
        if obj.type == 'LIGHT' and obj.name in LIGHTS:
            info = LIGHTS[obj.name]
            obj.data.energy = float(info["energy"]) * LIGHT_ENERGY_SCALE
            col = info["color"]
            obj.data.color = (col[0], col[1], col[2])

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
    out("PAVLAKA_BAKE: %d lightmap target(s)" % len(targets))

    meshes_meta = []
    errors = []
    used_names = set()
    for slice_index, obj in enumerate(targets):
        # name the slice after the node; de-dup (Godot allows same names under different
        # parents) by appending an index so files never collide
        base = re.sub(r'[^A-Za-z0-9_-]', '_', obj.name) or "mesh"
        fname = base
        n = 1
        while fname in used_names:
            fname = "%s_%d" % (base, n)
            n += 1
        used_names.add(fname)
        slice_file = fname + ".exr"
        size = int(SIZES.get(obj.name, DEFAULT_SIZE))
        try:
            bake_one(scene, obj, os.path.join(out_dir, slice_file), size)
            meshes_meta.append({"name": obj.name, "file": slice_file})
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
