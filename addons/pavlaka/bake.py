"""Bake a Godot-exported scene's lightmaps (multi-mesh).

  blender --background --python bake.py -- <glb> <out_dir> <params.json>

Imports the glb, finds every lightmap target (mesh with >=2 UV layers, i.e. it carries a
Godot UV2), and bakes irradiance (Diffuse, Direct+Indirect, Color OFF) into each target's
UV2. Each mesh becomes its own denoised linear EXR, sized to the per-mesh chunk size Godot
computed from world-space surface area (params "sizes"). Godot composites those into one
packed atlas.

Real materials are kept (the bake-target image node is injected into each mesh's own
material rather than replacing it), so indirect bounces pick up surface albedo and emissive
materials cast light.

Meshes are joined into batches (join_batches) and each batch bakes in one bake: Cycles bakes all
the images of one object in one render session, and a session's start is most of a small mesh's
bake. Each mesh still gets its own image and slice. A mesh that joining would change (mirrored or
unevenly scaled) bakes alone.

Light groups (params "groups"): lights and emissive surfaces in a group are left out of the main
bake; each group is baked again on its own (only its lights and emission, no sky), so the game can
add it to the lightmap at any strength. Light adds up, so the main bake plus every group at full
strength is the whole light. A group keeps only the TILE x TILE texel tiles of each mesh where its
light reaches its threshold (params "group_thresholds"; baked.json "groups").

The plugin runs this non-blocking and can't read stdout, so output is mirrored to
<out_dir>/bake.log and the whole run is wrapped so a fatal error still writes baked.json.
"""
import bpy
import math
import sys
import os
import re
import json
import traceback

import numpy as np

argv = sys.argv
rest = argv[argv.index("--") + 1:] if "--" in argv else []
glb = rest[0]
out_dir = rest[1] if len(rest) > 1 else os.path.dirname(glb)
os.makedirs(out_dir, exist_ok=True)

# bake parameters come from a JSON file written by the plugin
with open(rest[2], "r") as _pf:
    PARAMS = json.load(_pf)
# per-mesh chunk size (px), keyed by export key; Godot computed these from world area
SIZES = PARAMS.get("sizes", {})
DEFAULT_SIZE = 512
SAMPLES = int(PARAMS.get("samples", 256))
USE_GPU = bool(PARAMS.get("use_gpu", False))
MARGIN = int(PARAMS.get("bake_margin", 16))
INDIRECT_CLAMP = float(PARAMS.get("indirect_clamp", 0.0))
DENOISE = bool(PARAMS.get("denoise", True))
BOUNCES = int(PARAMS.get("bounces", 3))
AMBIENT = float(PARAMS.get("ambient_energy", 0.2))
AMBIENT_RGB = PARAMS.get("ambient_color", [1.0, 1.0, 1.0])
# name -> {"energy", "color":[r,g,b] linear, "group"}; used to override imported lights
LIGHTS = {l["name"]: l for l in PARAMS.get("lights", [])}
# object key -> {surface index -> emissive entry}; rebuilt because the glb drops emission textures
EMISSIVE = {}
for _em in PARAMS.get("emissive", []):
    EMISSIVE.setdefault(_em["object"], {})[int(_em["surface"])] = _em
# light group names; a light or emissive surface with group "" is in the main bake
GROUPS = list(PARAMS.get("groups", []))
TILE = int(PARAMS.get("group_tile", 16))
# per group: the irradiance under which its tile is dropped, invisible at its highest energy
THRESHOLDS = [float(t) for t in PARAMS.get("group_thresholds", [])]
# lightmap texels of one batch (join_batches): Blender keeps about 85 bytes a texel while it bakes
# (measured), so about 180 MB; a mesh with more bakes alone
BATCH_TEXELS = 1 << 21
MAX_SLOTS = 32000  # material slots of a joined object: Blender keeps at most 32766

_log = open(os.path.join(out_dir, "bake.log"), "w", encoding="utf-8")


def out(msg):
    print(msg)
    try:
        _log.write(str(msg) + "\n")
        _log.flush()
    except Exception:
        pass


def write_meta(meshes_meta, errors, groups_meta=()):
    meta = {
        "baked_exposure": 1.0,
        "meshes": meshes_meta,
        "groups": list(groups_meta),
        "errors": errors,
    }
    with open(os.path.join(out_dir, "baked.json"), "w") as f:
        json.dump(meta, f, indent=2)


def build_denoise_tree(image):
    """Wire image -> OIDN denoise -> output in the scene compositor, replacing any prior graph.
    Blender 5.0 moved the compositor onto a node-group datablock (scene.compositing_node_group)
    and swapped the Composite output node for a Group Output, so branch on the version."""
    sc = bpy.context.scene
    if bpy.app.version[0] >= 5:
        tree = sc.compositing_node_group
        if tree is None:
            tree = bpy.data.node_groups.new("PavlakaDenoise", "CompositorNodeTree")
            tree.interface.new_socket(name="Image", in_out="OUTPUT", socket_type="NodeSocketColor")
            sc.compositing_node_group = tree
        tree.nodes.clear()
        n_out = tree.nodes.new("NodeGroupOutput")
    else:
        sc.use_nodes = True
        tree = sc.node_tree
        tree.nodes.clear()
        n_out = tree.nodes.new("CompositorNodeComposite")
    n_img = tree.nodes.new("CompositorNodeImage"); n_img.image = image
    n_dn = tree.nodes.new("CompositorNodeDenoise")
    tree.links.new(n_img.outputs["Image"], n_dn.inputs["Image"])
    tree.links.new(n_dn.outputs["Image"], n_out.inputs["Image"])


def denoise_over(image, out_path, size):
    """Compositor OIDN denoise -> linear EXR at out_path (overwrites)."""
    sc = bpy.context.scene
    build_denoise_tree(image)
    sc.render.use_compositing = True
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


def setup_bake_target(me, obj_name):
    """Prepare a mesh to bake into without discarding real materials (so albedo/emission still
    drive bounces): each slot gets its own material copy with a bake-target image node. Returns
    the image nodes; bake_batch gives them each bake's image."""
    if not me.materials:
        m = bpy.data.materials.new("BakeMat_%s" % obj_name)
        m.use_nodes = True
        me.materials.append(m)
    nodes = []
    for i in range(len(me.materials)):
        m = me.materials[i]
        if m is None:
            m = bpy.data.materials.new("BakeMat_%s_%d" % (obj_name, i))
            m.use_nodes = True
        else:
            m = m.copy()  # unique to this mesh
            if not m.use_nodes:
                m.use_nodes = True
        me.materials[i] = m
        nodes.append(m.node_tree.nodes.new("ShaderNodeTexImage"))
    return nodes


def activate(nodes):
    """Make each bake-target image node the active node of its material (where the bake writes)."""
    for tex in nodes:
        nt = tex.id_data
        for n in nt.nodes:
            n.select = False
        tex.select = True
        nt.nodes.active = tex


def size_of(name):
    """A mesh's slice size (px)."""
    return int(SIZES.get(name, DEFAULT_SIZE))


def joinable(obj):
    """Whether a mesh bakes the same joined to others: its transform only turns, moves and scales
    it evenly (joined, a mirrored or unevenly scaled mesh's normals come out wrong), it can be
    selected, and nothing hangs off it (joining takes children off their parent)."""
    m = np.array(obj.matrix_world)[:3, :3]
    g = m.T @ m
    k = np.trace(g) / 3
    return (np.linalg.det(m) > 0 and np.abs(g - k * np.eye(3)).max() <= 1e-6 * k
            and not obj.children and obj.visible_get() and not obj.hide_select)


def join_batches(targets):
    """Join the targets, in their order, into objects of at most BATCH_TEXELS texels of lightmap
    and MAX_SLOTS materials, one bake each (bake_batch). The meshes of a batch have the same UV
    layer names (joining merges layers by name; materials refer to them by name); a mesh that
    isn't `joinable` is a batch of its own. Returns [(object, [its meshes' names], error)]: the
    object None and the error where joining failed. The targets' other objects are gone."""
    batches, texels, slots, layers, open_batch = [], 0, 0, None, False
    for obj in targets:
        size, uvs, n = size_of(obj.name), [layer.name for layer in obj.data.uv_layers], len(obj.data.materials)
        ok = joinable(obj)
        if not (open_batch and ok and uvs == layers and texels + size * size <= BATCH_TEXELS
                and slots + n <= MAX_SLOTS):
            batches.append([])
            texels, slots, layers = 0, 0, uvs
        batches[-1].append(obj)
        texels += size * size
        slots += n
        open_batch = ok
    joined = []
    for objs in batches:
        names = [o.name for o in objs]
        try:
            faces = sum(len(o.data.polygons) for o in objs)
            bpy.ops.object.select_all(action='DESELECT')
            for o in objs:
                o.select_set(True)
            bpy.context.view_layer.objects.active = objs[0]
            if len(objs) > 1:
                bpy.ops.object.join()
            obj = bpy.context.view_layer.objects.active
            if len(obj.data.polygons) != faces:  # a join can leave meshes out without an error
                raise RuntimeError("joined %d of %d faces" % (len(obj.data.polygons), faces))
            obj.data.uv_layers.active_index = 1  # the bake's UVs: Godot's UV2
            joined.append((obj, names, None))
        except Exception as e:
            out("PAVLAKA_BAKE: ERROR joining %s:\n%s" % (", ".join(names), traceback.format_exc()))
            joined.append((None, names, e))
    return joined


def bake_batch(scene, obj, slices):
    """Bake the meshes joined in `obj` (join_batches) in one bake, each into its own image, and
    save each image (denoised) as its slice: slices [(mesh name, path, size, image nodes)].
    Returns {mesh name: error} for the slices not saved (every one when the bake failed); the
    errors are logged."""
    imgs = []
    try:
        try:
            for name, path, size, nodes in slices:
                img = bpy.data.images.new("LM_%s" % name, width=size, height=size,
                                          float_buffer=True, is_data=True)
                imgs.append(img)
                for tex in nodes:
                    tex.image = img
                activate(nodes)
            bpy.ops.object.select_all(action='DESELECT')
            obj.select_set(True)
            bpy.context.view_layer.objects.active = obj
            scene.cycles.samples = SAMPLES
            bpy.ops.object.bake(type='DIFFUSE', pass_filter={'DIRECT', 'INDIRECT'},
                                margin=MARGIN, use_clear=True)
        except Exception as e:
            out("PAVLAKA_BAKE: ERROR baking %s:\n%s" % (", ".join(sl[0] for sl in slices), traceback.format_exc()))
            return {sl[0]: e for sl in slices}
        failed = {}
        for (name, path, size, _), img in zip(slices, imgs):
            try:
                img.filepath_raw = path
                img.file_format = 'OPEN_EXR'
                img.save()  # raw bake, kept if denoise can't produce output below
                if DENOISE and not denoise_over(img, path, size):
                    out("PAVLAKA_BAKE: WARNING: denoise produced no output for %s; using raw bake" % name)
            except Exception as e:
                out("PAVLAKA_BAKE: ERROR saving %s:\n%s" % (name, traceback.format_exc()))
                failed[name] = e
        return failed
    finally:
        for img in imgs:  # free them: light groups bake every mesh again
            bpy.data.images.remove(img)


def lit_tiles(path, threshold):
    """The TILE x TILE tiles of a baked slice where any texel's light passes `threshold`:
    [[x, y, w, h]] in the file's texels (top row first; edge tiles are cut to the slice), and
    every tile's brightest value (an array, rows of tiles)."""
    img = bpy.data.images.load(path, check_existing=False)
    w, h = img.size
    px = np.empty(w * h * 4, np.float32)
    img.pixels.foreach_get(px)
    bpy.data.images.remove(img)
    # Blender's pixel rows start at the bottom, the file's at the top
    lum = px.reshape(h, w, 4)[::-1, :, :3].max(axis=2)
    th, tw = -(-h // TILE), -(-w // TILE)
    pad = np.zeros((th * TILE, tw * TILE), np.float32)
    pad[:h, :w] = lum
    peak = pad.reshape(th, TILE, tw, TILE).max(axis=(1, 3))
    tiles = []
    for ty, tx in zip(*np.nonzero(peak > threshold)):
        x, y = int(tx) * TILE, int(ty) * TILE
        tiles.append([x, y, min(TILE, w - x), min(TILE, h - y)])
    return tiles, peak


class Passes:
    """Which light a bake sees: the main bake ("") has the lights and emissive surfaces of no
    group, and the sky; a group's bake has only that group's lights and emission."""

    def __init__(self, scene, sockets):
        self.lights = [(o, LIGHTS.get(o.name, {}).get("group", "")) for o in bpy.data.objects
                       if o.type == 'LIGHT']
        self.sockets = sockets  # (Emission Strength socket, energy, group)
        bg = scene.world.node_tree.nodes["Background"]
        self.world = (bg.inputs[1], bg.inputs[1].default_value)

    def set(self, group):
        for o, g in self.lights:
            o.hide_render = g != group
        for sock, energy, g in self.sockets:
            sock.default_value = energy if g == group else 0.0
        self.world[0].default_value = self.world[1] if group == "" else 0.0


def setup_device(scene):
    """Render on GPU if requested and available, else CPU. Never fails the bake."""
    if not USE_GPU:
        scene.cycles.device = 'CPU'
        return
    try:
        prefs = bpy.context.preferences.addons['cycles'].preferences
        prefs.get_devices()
        # Prefer CUDA over OptiX on NVIDIA: OptiX's hardware RT cores have a different
        # self-intersection epsilon that leaks light through thin walls; CUDA matches the CPU.
        for backend in ('CUDA', 'OPTIX', 'HIP', 'METAL', 'ONEAPI'):
            try:
                prefs.compute_device_type = backend
            except TypeError:
                continue  # backend not supported by this build
            prefs.get_devices()
            n = 0
            for d in prefs.devices:
                on = (d.type == backend)
                d.use = on
                n += 1 if on else 0
            if n > 0:
                scene.cycles.device = 'GPU'
                out("PAVLAKA_BAKE: GPU enabled (%s, %d device(s))" % (backend, n))
                return
        out("PAVLAKA_BAKE: no GPU compute device found; using CPU")
    except Exception as e:
        out("PAVLAKA_BAKE: GPU setup failed (%s); using CPU" % e)
    scene.cycles.device = 'CPU'


# Godot draws a surface lit by a light of energy E as albedo * E * cos (directional), or albedo *
# E * cos * attenuation(d) (omni, spot). Cycles' colour-off diffuse bake gives S cos / pi for a sun
# of strength S, and P cos / (4 pi^2 d^2) for a point or spot light of P watts (measured). So a sun
# gets E * pi, a point or spot light E * 4 pi^2, and a node tree turns Cycles' 1/d^2 into Godot's
# attenuation.
SUN_SCALE = math.pi
POINT_SCALE = 4.0 * math.pi * math.pi


def set_light(obj, info):
    """An imported light made to light as Godot draws it (info: from baker.gd)."""
    lt = obj.data
    col = info["color"]
    lt.color = (col[0], col[1], col[2])
    if lt.type == 'SUN':
        lt.energy = float(info["energy"]) * SUN_SCALE
        lt.angle = math.radians(float(info.get("angular_distance", 0.0)))
        return
    lt.energy = float(info["energy"]) * POINT_SCALE
    lt.shadow_soft_size = float(info.get("size", 0.0))  # Godot's light_size, as the light's radius
    if lt.type == 'SPOT':
        if float(info.get("spot_angle", 45.0)) > 90.0:
            lt.type = 'POINT'  # Cycles' cone stops at a hemisphere; the node tree cuts Godot's
        else:
            lt.spot_size = 2.0 * math.radians(float(info.get("spot_angle", 45.0)))
            lt.spot_blend = 0.0
    if "range" in info:
        godot_attenuation(lt, info)


def _math(nt, op, a, b=None):
    n = nt.nodes.new("ShaderNodeMath")
    n.operation = op
    for i, v in enumerate((a, b)):
        if v is None:
            continue
        if isinstance(v, (int, float)):
            n.inputs[i].default_value = float(v)
        else:
            nt.links.new(v, n.inputs[i])
    return n.outputs[0]


def godot_attenuation(lt, info):
    """Godot's falloff and cone on a Cycles point or spot light (its emission strength, per shading
    point). Godot: d^-attenuation * max(1 - (d / range)^4, 0)^2; a spot also 1 - rim^a, rim =
    (1 - cos t) / (1 - cos spot_angle), t the angle off its axis, a its spot_angle_attenuation.
    Cycles already falls off by 1/d^2, so the strength is d^(2 - attenuation) times the rest. The
    light path's ray length is d; the texture coordinate's normal is the direction in the light's
    space (a spot points along -z). A spot wider than a hemisphere bakes as a point light with this
    cone (set_light)."""
    lt.use_nodes = True
    nt = lt.node_tree
    em = next((n for n in nt.nodes if n.type == 'EMISSION'), None)
    if em is None:
        return
    d = nt.nodes.new("ShaderNodeLightPath").outputs["Ray Length"]
    f = _math(nt, 'POWER', _math(nt, 'MAXIMUM', d, 1e-4), 2.0 - float(info.get("attenuation", 1.0)))
    t4 = _math(nt, 'POWER', _math(nt, 'DIVIDE', d, max(float(info["range"]), 1e-4)), 4.0)
    window = _math(nt, 'POWER', _math(nt, 'MAXIMUM', _math(nt, 'SUBTRACT', 1.0, t4), 0.0), 2.0)
    f = _math(nt, 'MULTIPLY', f, window)
    if "spot_angle" in info:
        normal = nt.nodes.new("ShaderNodeTexCoord").outputs["Normal"]
        xyz = nt.nodes.new("ShaderNodeSeparateXYZ")
        nt.links.new(normal, xyz.inputs[0])
        cos_t = _math(nt, 'MULTIPLY', xyz.outputs["Z"], -1.0)
        cut = 1.0 - math.cos(math.radians(float(info.get("spot_angle", 45.0))))
        rim = _math(nt, 'MAXIMUM', _math(nt, 'DIVIDE', _math(nt, 'SUBTRACT', 1.0, cos_t), max(cut, 1e-4)), 1e-4)
        cone = _math(nt, 'SUBTRACT', 1.0, _math(nt, 'POWER', rim, float(info.get("spot_angle_attenuation", 1.0))))
        f = _math(nt, 'MULTIPLY', f, _math(nt, 'MAXIMUM', cone, 0.0))
    nt.links.new(f, em.inputs["Strength"])


def apply_emission(obj):
    """Rebuild emission from Godot's material on each slot listed in EMISSIVE, since the glb
    round-trip keeps the emission color but drops the emission texture. Overrides the Principled
    BSDF's emission inputs (clearing any from the import) with color * energy and, if present, the
    saved texture sampled through the model's base UV. Returns each slot's (Emission Strength
    socket, energy, light group), so a bake pass can turn its emission off."""
    slots = EMISSIVE.get(obj.name)
    if not slots:
        return []
    me = obj.data
    uv0 = me.uv_layers[0].name if me.uv_layers else ""
    sockets = []
    for i in range(len(me.materials)):
        em = slots.get(i)
        mat = me.materials[i]
        if em is None or mat is None or not mat.use_nodes:
            continue
        if mat.users > 1:  # shared with another mesh (the glb merges equal materials): its own copy
            mat = mat.copy()
            me.materials[i] = mat
        nt = mat.node_tree
        bsdf = next((n for n in nt.nodes if n.type == 'BSDF_PRINCIPLED'), None)
        if bsdf is None:
            continue
        ec = bsdf.inputs.get("Emission Color") or bsdf.inputs.get("Emission")
        es = bsdf.inputs.get("Emission Strength")
        if ec is None or es is None:
            continue
        for inp in (ec, es):
            for link in list(inp.links):
                nt.links.remove(link)
        es.default_value = float(em.get("energy", 1.0))
        sockets.append((es, es.default_value, em.get("group", "")))
        color = em.get("color", [0.0, 0.0, 0.0])
        tex_file = em.get("texture", "")
        if not tex_file:
            ec.default_value = (color[0], color[1], color[2], 1.0)
            continue
        tex = nt.nodes.new("ShaderNodeTexImage")
        tex.image = bpy.data.images.load(os.path.join(out_dir, tex_file))
        tex.image.colorspace_settings.name = 'sRGB'
        if uv0:
            uvn = nt.nodes.new("ShaderNodeUVMap")
            uvn.uv_map = uv0
            nt.links.new(uvn.outputs["UV"], tex.inputs["Vector"])
        op = em.get("op", "add")
        # default Godot emission (black + ADD, or white + MULTIPLY) is just the texture; otherwise
        # combine texture with the constant color the same way Godot's emission operator does.
        identity = (op == "add" and color == [0.0, 0.0, 0.0]) or \
                   (op == "multiply" and color == [1.0, 1.0, 1.0])
        if identity:
            nt.links.new(tex.outputs["Color"], ec)
        else:
            vm = nt.nodes.new("ShaderNodeVectorMath")
            vm.operation = 'MULTIPLY' if op == "multiply" else 'ADD'
            vm.inputs[1].default_value = (color[0], color[1], color[2])
            nt.links.new(tex.outputs["Color"], vm.inputs[0])
            nt.links.new(vm.outputs["Vector"], ec)
    return sockets


def main():
    out("PAVLAKA_BAKE: Blender %s, glb=%s" % (".".join(map(str, bpy.app.version)), glb))
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=glb)

    scene = bpy.context.scene
    scene.render.engine = 'CYCLES'
    setup_device(scene)
    scene.cycles.samples = SAMPLES
    scene.cycles.diffuse_bounces = BOUNCES # indirect GI bounce count for the irradiance bake
    scene.cycles.sample_clamp_indirect = INDIRECT_CLAMP # 0 = off; clamps fireflies
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
        # apply sky rotation (panorama is baked unrotated) via TexCoord -> Mapping -> env texture
        sky_rot = PARAMS.get("sky_rotation", [0.0, 0.0, 0.0])
        if any(sky_rot):
            tcoord = wnt.nodes.new("ShaderNodeTexCoord")
            mapping = wnt.nodes.new("ShaderNodeMapping")
            mapping.inputs["Rotation"].default_value = (sky_rot[0], sky_rot[1], sky_rot[2])
            wnt.links.new(tcoord.outputs["Generated"], mapping.inputs["Vector"])
            wnt.links.new(mapping.outputs["Vector"], env_tex.inputs["Vector"])
    else:
        # flat ambient dome: set a real color (new-world default is near-black), AMBIENT = brightness
        bg.inputs[0].default_value = (AMBIENT_RGB[0], AMBIENT_RGB[1], AMBIENT_RGB[2], 1.0)
        bg.inputs[1].default_value = AMBIENT

    # Override imported lights with Godot's: energy, colour, falloff, cone, size (set_light)
    for obj in bpy.data.objects:
        if obj.type == 'LIGHT' and obj.name in LIGHTS:
            set_light(obj, LIGHTS[obj.name])

    targets = [o for o in bpy.data.objects
               if o.type == 'MESH' and len(o.data.uv_layers) >= 2]
    targets.sort(key=lambda o: o.name)  # stable slice order
    out("PAVLAKA_BAKE: %d lightmap target(s)" % len(targets))
    for o in targets:
        if o.data.users > 1:  # each its own mesh: its own materials and image (and joined apart)
            o.data = o.data.copy()
    # bake targets first get their own material copies (with the image node the bake writes),
    # then emission is rebuilt on the materials the bake actually uses
    bake_nodes = {o.name: setup_bake_target(o.data, o.name) for o in targets}
    sockets = []
    for obj in bpy.data.objects:
        if obj.type == 'MESH':
            sockets += apply_emission(obj)
    passes = Passes(scene, sockets)
    passes.set("")

    bake = scene.render.bake
    bake.use_pass_direct = True
    bake.use_pass_indirect = True
    bake.use_pass_color = False        # irradiance, not radiance
    bake.margin = MARGIN
    bake.margin_type = 'EXTEND'
    bake.use_clear = True

    names = [o.name for o in targets]
    used_names = set()
    fnames = {}
    for name in names:
        # name the slice after the node, appending an index to de-dup colliding names
        base = re.sub(r'[^A-Za-z0-9_-]', '_', name) or "mesh"
        fname = base
        n = 1
        while fname in used_names:
            fname = "%s_%d" % (base, n)
            n += 1
        used_names.add(fname)
        fnames[name] = fname
    batches = join_batches(targets)
    out("PAVLAKA_BAKE: %d bake(s) per pass" % len(batches))

    def slices(batch, suffix):
        return [(n, os.path.join(out_dir, fnames[n] + suffix), size_of(n), bake_nodes[n]) for n in batch]

    def bake(obj, batch, joining, suffix):
        """{mesh name: error} of a batch's bake (bake_batch), every mesh failed where it didn't join."""
        return {n: joining for n in batch} if obj is None else bake_batch(scene, obj, slices(batch, suffix))

    meshes_meta = []
    errors = []
    for obj, batch, joining in batches:
        failed = bake(obj, batch, joining, ".exr")
        for name in batch:
            if name in failed:
                errors.append("%s: %s" % (name, failed[name]))
                continue
            slice_file = fnames[name] + ".exr"
            meshes_meta.append({"name": name, "file": slice_file})
            # drop a marker so Godot can stream this mesh into the live preview now. Write to a
            # temp file then rename so Godot's poll never reads a half-written .done.
            done_path = os.path.join(out_dir, fnames[name] + ".done")
            with open(done_path + ".tmp", "w") as _mf:
                json.dump({"name": name, "file": slice_file}, _mf)
            os.replace(done_path + ".tmp", done_path)

    # each light group on its own: its tiles of every mesh its light reaches
    groups_meta = []
    for gi, group in enumerate(GROUPS):
        passes.set(group)
        kept = total = 0
        counts = {}  # tiles kept at other thresholds, to tune the threshold
        threshold = THRESHOLDS[gi] if gi < len(THRESHOLDS) else 0.0005
        for obj, batch, joining in batches:
            failed = bake(obj, batch, joining, ".g%d.exr" % gi)
            for name in batch:
                if name in failed:
                    errors.append("%s (light group %s): %s" % (name, group, failed[name]))
                    continue
                slice_file = "%s.g%d.exr" % (fnames[name], gi)
                path = os.path.join(out_dir, slice_file)
                try:
                    tiles, peaks = lit_tiles(path, threshold)
                except Exception as e:
                    errors.append("%s (light group %s): %s" % (name, group, e))
                    out("PAVLAKA_BAKE: ERROR reading %s for light group %s:\n%s"
                        % (name, group, traceback.format_exc()))
                    continue
                total += peaks.size
                for t in (1e-4, 1e-3, 1e-2):
                    counts[t] = counts.get(t, 0) + int((peaks > t).sum())
                if tiles:
                    kept += len(tiles)
                    groups_meta.append({"group": gi, "name": name, "file": slice_file, "tiles": tiles})
                else:
                    os.remove(path)
        out("PAVLAKA_BAKE: light group '%s': %d of %d tiles lit above %g (above 1e-4: %d, 1e-3: %d, 1e-2: %d)"
            % (group, kept, total, threshold, counts.get(1e-4, 0), counts.get(1e-3, 0), counts.get(1e-2, 0)))
    passes.set("")

    write_meta(meshes_meta, errors, groups_meta)
    out("PAVLAKA_BAKE: done (%d/%d slices, %d light group(s), %d error(s))"
        % (len(meshes_meta), len(names), len(GROUPS), len(errors)))


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
