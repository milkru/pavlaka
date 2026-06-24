# Blender Lightmap Baking Integration for Godot

## Implementation Status (current)

**Implemented and working** on Godot 4.7 + Blender 4.1.1. See `README.md` for usage; the
plugin lives in `addons/pavlaka/`. This document is the design record and source-grounded
findings; the milestone notes further down (M0–M2c) trace how it was validated.

Shipped: a `LightmapBlenderGI` node (extends `LightmapGI`) with a selection-driven "Bake
with Blender" button; per-mesh irradiance bake in headless Blender (Diffuse / Direct+
Indirect / Color OFF, OIDN-denoised) → per-mesh EXR slices → `CompressedTexture2DArray`
→ a combined `LightmapGIData` saved as `.lmbake` and assigned to the node. Non-blocking
bake with a progress dialog + Cancel.

### Fixes / pitfalls found during implementation (beyond the source study)

- **Empty probe points ⇒ culled lightmap** — a static `LightmapGIData` needs ≥1 probe
  point + real bounds, or `set_capture_data` forces an empty AABB and the instance is
  culled (renders unlit).
- **Hidden nodes + `KHR_node_visibility`** — Godot 4.7 emits this *required* glTF
  extension for hidden nodes; Blender < 5.2 rejects the file. We export a reconstructed
  scene of visible meshes/lights only.
- **`duplicate()` breaks on CSG** ("child disappeared while duplicating") and dropped
  lights → only ambient baked. Fixed by building the export tree from scratch (copied
  `MeshInstance3D` + `Light3D` in world space) instead of duplicating the live scene.
- **Brand-new files after folder deletion** — `reimport_files` can't find files unknown
  to the EditorFileSystem; trigger a `scan()` and wait for `filesystem_changed`. (And the
  scan itself imports them, so calling `reimport_files` again trips a "recursive reimport"
  guard — don't.)
- **Black ambient** — a new Blender world's Background *color* defaults to ~black; set it
  white so `ambient_energy` controls actual dome brightness.
- **Stale UID warnings** — preserve an existing `.import` so the texture UID is stable
  across re-bakes.
- **Editor crash (signal 11)** — our progress dialog was *exclusive* and force-closed the
  editor's own reimport `ProgressDialog`, corrupting its task list. Made it non-exclusive
  and hidden during the import stage.
- **GUI-only bake** — the editor's `ResourceLoader.load` only resolves already-imported
  source files (headless on-demand-imports), so baking must run in the GUI editor.

### Remaining (optional polish)

Light-energy calibration (use each light's real intensity vs the fixed `sun_energy`),
`WorldEnvironment`/sky → bake, auto-generate UV2 for meshes that lack it, space-efficient
atlas packing.

## Vision

Create a Godot editor plugin that uses Blender as an external lightmap baker, then imports the baked output back into Godot as native `LightmapGIData`.

The intended workflow is:

```text
Godot editor button
    -> run Blender headless
    -> Blender bakes lightmaps
    -> Blender exports textures + metadata
    -> Godot imports the result
    -> Godot creates/saves LightmapGIData / .lmbake
    -> scene uses Godot's native LightmapGI runtime
```

The tool targets a specific Godot version. Long-term compatibility is not a goal.

## Architecture

### Godot Plugin

Owns the editor workflow.

Responsibilities:

* Expose a Generate Lightmaps action.
* Prepare/export scene data needed by Blender.
* Run Blender headless.
* Read Blender output.
* Create/update `LightmapGIData`.
* Save generated `.lmbake`.
* Assign the result to the scene's `LightmapGI`.

### Blender Side

Owns the bake.

Responsibilities:

* Run headless.
* Load/import scene data.
* Use the expected UV2/lightmap layout.
* Bake atlas textures.
* Export textures and metadata required by Godot.

## Data Exchange

Blender will likely need to export:

* Baked EXR/HDR lightmap textures.
* Object or node identifiers.
* Per-object atlas mapping.
* UV scale/offset or atlas rect information.
* Lightmap texture index / slice index.
* Sub-instance information if required by Godot.

The exact schema should be derived from the target Godot version's `LightmapGIData` implementation.

## Key Feasibility Checks

### Can LightmapGIData Be Created Externally?

Main go/no-go check.

Verify that a plugin can:

* Create `LightmapGIData`.
* Populate it.
* Save it.
* Reload it.
* Use it at runtime.

### Does LightmapGIData Contain All Required Runtime Data?

Verify whether `LightmapGIData` is a complete representation of a baked lightmap solution, or whether `LightmapGI` and/or other scene resources contain additional state that must also be generated.

Questions:

* Is `LightmapGIData` sufficient by itself?
* Does `LightmapGI` store additional bake-related state?
* Are there hidden dependencies between `LightmapGIData` and scene objects?
* Can a valid bake be recreated solely from externally generated textures and metadata?

This should be verified directly from the target Godot version's source code.

### Who Owns UV2 And Atlas Packing?

Need to decide whether:

* Godot generates UV2 and Blender only bakes into that layout.
* Blender owns UV2 generation and atlas packing.

This decision affects the metadata Blender must export.

### Texture Requirements

Verify:

* EXR/HDR requirements.
* Color space expectations.
* Compression settings.
* Mip behavior.
* Texture array or multi-texture behavior.
* Requirements for non-directional lightmaps.

### Directional Lightmaps

Determine later:

* Additional textures required.
* Spherical harmonics requirements.
* Capture data requirements.
* Shadow mask requirements.

Initial support should focus on a single non-directional lightmap atlas.

## Main Risks

* `LightmapGIData` may not be fully constructible through public APIs.
* `LightmapGI` may depend on additional state not stored in `LightmapGIData`.
* Per-instance user data may depend on internal assumptions.
* Blender and Godot may disagree on atlas coordinates, UV conventions, or color space.
* Node-path-based mappings may become unstable with imported or instanced scenes.
* Directional lightmaps may require additional data structures.

## Minimum Proof Of Concept

Prove only this:

```text
one mesh
one UV2 layout
one baked lightmap texture
one LightmapGIData resource generated externally
scene renders using Godot LightmapGI
```

If this works, the overall project is viable.

---

# Findings — Verified Against Godot 4.7.1 Source

All claims below are grounded in the `godot-4.7` source tree (4.7.1-rc1). File:line
references use that tree. Verified June 2026.

## Verdict: VIABLE

Every feasibility check passed. A GDScript editor plugin can build a complete,
working `LightmapGIData` from externally-baked textures + metadata, save it, and
have Godot render static meshes with it at runtime — **no GDExtension or engine
fork required**. The internal C++ bake path does not need to run.

## The Data Contract (how to build a LightmapGIData externally)

The engine's own baker does exactly this (`lightmap_gi.cpp:1517` instantiate →
populate → `:1691` `ResourceSaver::save()`), so the path is fully supported:

1. Instantiate `LightmapGIData` (its internal `lightmap` RID is auto-created in the
   constructor — `lightmap_gi.cpp:389`).
2. `set_lightmap_textures([TextureLayered, ...])` — non-empty. This setter also
   pushes the combined texture RID to the RenderingServer as a side effect
   (`lightmap_gi.cpp:117-144`), so it fully wires the renderer.
3. For each baked mesh: `add_user(path, uv_scale, slice_index, sub_instance)`
   (`bind` at `lightmap_gi.cpp:357`). For a normal `MeshInstance3D`, `sub_instance = -1`.
4. Keep `uses_spherical_harmonics = false` for the non-directional MVP.
5. Capture/probe data: optional for static meshes. If going through the GDScript
   `probe_data` dictionary hook, supply all keys with empty/zero values (below).
6. `ResourceSaver.save(data, "res://path.lmbake")`. Prefer this over hand-authoring
   `.tres` — it sidesteps the packed-array/dictionary formatting traps.
7. Assign to the node: `LightmapGI.set_light_data(data)`.

### Per-user record (`add_user`) — `lightmap_gi.cpp:357`, `:1731-1754`

| Field | Type | Meaning |
|---|---|---|
| `path` | NodePath | Resolved **relative to the LightmapGI node** at runtime, not the scene root. |
| `uv_scale` | Rect2 | `.position` = atlas offset (0..1), `.size` = atlas scale (0..1). |
| `slice_index` | int | Which `TextureLayered` array layer (atlas page) the island lives on. |
| `sub_instance` | int | `-1` for a normal MeshInstance3D; `>=0` selects a MultiMesh sub-instance. |

Runtime sampling is **`atlas_uv = mesh_uv2 * uv_scale.size + uv_scale.position`**,
layer `slice_index` (`scene_forward_clustered.glsl:1834-1836`;
Rect2→vec4 mapping `render_forward_clustered.h:351-356`). The mesh's stored UV2 stays
**0..1 island-local** — do NOT pre-bake atlas offset/scale into UV2.

## Answers to the Open Questions

### Can LightmapGIData be created externally? — YES
Every setter needed to populate the resource is `ClassDB::bind_method`-bound
(`lightmap_gi.cpp:341-386`): `set_lightmap_textures`, `add_user`, `clear_users`,
`set_uses_spherical_harmonics`, plus serialization hooks `_set_user_data` /
`_set_probe_data`. Inspector flags (READ_ONLY / INTERNAL / NO_EDITOR) only hide
fields from the editor UI — they still serialize and are callable from script.
Only true gap: `update_shadowmask_mode` is unbound (irrelevant to non-directional MVP).

### Does LightmapGIData contain all required runtime data? — YES for static
Static surfaces render entirely from `lightmap_textures` + the per-user
`uv_scale`/`slice_index` bound via `instance_geometry_set_lightmap`
(`lightmap_gi.cpp:1747/1752`). No hidden state on the `LightmapGI` node is required
for static rendering. The node's render base is set to the data's RID in
`set_light_data` (`:1798`).

### Capture/probe data required? — NO (static only)
The static render path (`INSTANCE_FLAGS_USE_LIGHTMAP`,
`scene_forward_clustered.glsl:~1830`) never reads SH/BSP/tetrahedra. Capture data is
a mutually-exclusive branch used only by `GI_MODE_DYNAMIC` objects. Empty capture is
explicitly handled (`lightmap_gi.cpp:238-250`). Minimal valid `probe_data` dictionary
(all keys mandatory): empty `points`/`point_sh`/`tetrahedra`/`bsp`, `bounds = AABB()`,
`interior = false`, `baked_exposure = 1.0`, `lightprobe_hash = 0`.

### Who owns UV2 and atlas packing?
Godot normally generates UV2 at **import** time via xatlas (`lightmap_unwrap_cached`,
`mesh.cpp:2085`; import option `meshes/lightmap_texel_size`, default 0.2). The bake
**never** regenerates UV2 — it reuses whatever `ARRAY_TEX_UV2` exists. This is the
key remaining architecture decision (see "Open Decision" below).

### Texture requirements
- **Type:** array of `TextureLayered` (imported as `CompressedTexture2DArray`). Atlas
  pages = array layers; multiple pages stacked **vertically** within one texture
  (`slices/vertical = N`, `slices/horizontal = 1`).
- **Format:** OpenEXR, half-float **RGBA (`FORMAT_RGBAH`)**, alpha = 1.0. Final GPU
  format for opaque HDR lightmaps is **RGBE9995, uncompressed, no mipmaps**.
- **Color space:** **raw linear radiance** — no sRGB/gamma, no Filmic/AgX/tonemap. In
  Blender export EXR with view transform = Raw/Standard.
- **`.import` settings:** `importer=2d_array_texture`, `type=CompressedTexture2DArray`,
  `compress/mode=2`, `compress/channel_pack=1`, `mipmaps/generate=false`,
  `slices/vertical=<count>`.

### Exposure normalization (critical)
`stored_pixel = linear_radiance × baked_exposure`; runtime multiplies the sample by
`enf / baked_exposure` (`render_forward_clustered.cpp:1238-1240`). **Simplest correct
recipe: store raw linear radiance, set `baked_exposure = 1.0`, assign no
`CameraAttributes` to the LightmapGI node** → factors cancel, true radiance renders.
Any mismatch between baked-in factor and stored `baked_exposure` = uniformly wrong
brightness.

### Serialization
`LightmapGIData` has no custom `_get_property_list`/`_set`/`_get` — 100% standard
property serialization. Extension is **`.lmbake`** (`RES_BASE_EXTENSION`,
`lightmap_gi.h:45`; editor save `lightmap_gi_editor_plugin.cpp:100`). Textures are
**external** files referenced via `ExtResource`, never embedded. `user_data` is a flat
stride-4 array (hard-fails if `len % 4 != 0`); `probe_data` is a 7-key dictionary.
Programmatic `ResourceSaver.save()` round-trips cleanly.

### Directional lightmaps (deferred)
SH/directional uses **4 slices per atlas page** (L0, L1n1, L1_0, L1p1;
`lightmapper_rd.cpp:1291-1292`), L1 bands encoded `coeff*0.5 + 0.5`
(`scene_forward_clustered.glsl:1847-1849`). Stay non-directional for the MVP.

## Pitfalls (resolved/sharpened)

1. **Y-flip (verify-once, not hard).** Godot packs top-left origin, +Y down; Blender
   UV origin is bottom-left, +Y up. The atlas image, UV2, and `uv_scale.position.y`
   must agree. Trivial remap, but it fails *silently* (wrong-looking lighting, no
   error) — verify once with an asymmetric test island.
2. **UV2 must stay 0..1 island-local** — atlas remap is applied at runtime via
   `uv_scale`. Pre-baking it into UV2 *and* providing a non-identity `uv_scale`
   double-transforms.
3. **Seams — Blender already covers this.** Godot's import path runs zero
   post-processing on the texture we hand it, so the atlas must be final-quality on
   arrival. Blender's native bake provides the two that matter: **bake margin (Extend
   type)** for dilation and **OIDN denoise**. Cross-island seam blending (Godot does it
   internally) is the only thing Blender doesn't auto-do — pure polish, skip it. There
   is no need to replicate Godot's internal passes; just enable margin + denoise.
4. **NodePath relative to the LightmapGI node** (not scene root). Wrong base → user
   silently skipped (WARN only). Unstable under reparenting/instancing.
5. **Silent-skip family:** empty/null textures bind but render black with no error;
   `slice_index`/`uv_scale` are unvalidated — wrong values silently sample the wrong
   atlas region. Uniform layer dimensions are required across a `TextureLayered`.
6. **Empty probe points ⇒ empty lightmap AABB ⇒ nothing renders (POC-confirmed).**
   `set_capture_data` only applies the bounds you pass when `points` is non-empty
   (`lightmap_gi.cpp:238`); with empty `points` it forces `lightmap_set_probe_bounds(
   AABB())`. The lightmap *instance's* cull AABB comes from that
   (`renderer_scene_cull.cpp:2047` → `lightmap_get_aabb`), so an empty AABB means the
   instance is never gathered into the visible-lightmaps list, `lightmap_cull_index`
   stays −1 (`render_forward_clustered.cpp:1005-1015`), the `USE_LIGHTMAP` flag is never
   set, and meshes render with NO lightmap (no error, no warning). **Fix for a static,
   probe-less lightmap: supply one dummy probe point + 9 SH colors (empty
   tetrahedra/bsp are valid) and real `bounds` enclosing the geometry.** Verified in the
   POC: empty points → gray; one point + bounds → renders.

Note (directional only, deferred): if `uses_spherical_harmonics = true` you MUST also
set `_uses_packed_directional = true` or `_assign_lightmaps()` aborts the whole node
(`ERR_FAIL_COND_MSG`, `lightmap_gi.cpp:1707`). Irrelevant while non-directional — keep
both false.

## Open Decision: UV2 Ownership

Resolved facts above leave one fork that determines the whole pipeline integration:

- **(A) Blender owns UV2 + packing + bake.** Best unwrap quality (the original
  motivation), but Blender's UV2 must get *into* the Godot mesh (round-trip the mesh,
  or patch its `ARRAY_TEX_UV2`), and our `uv_scale`/`slice_index` must match exactly.
  More invasive integration.
- **(B) Godot owns UV2 (xatlas at import), Blender only bakes into it.** Blender
  receives meshes with existing UV2 + Godot's atlas layout, bakes, returns EXR. Simple,
  non-invasive — but inherits xatlas unwrap quality, undercutting the reason to use
  Blender.

This is the next decision to make before building past M1.

## POC Status

- **M0 + M1 — DONE (2026-06-24).** `poc/smoke_test_headless.gd` builds a `LightmapGIData`
  purely from script, saves to `.lmbake`, reloads — all checks PASS (confirms textures
  must be external, not embedded). `poc/render_test.gd` builds one externally-authored
  `LightmapGIData` (in-memory atlas, one `add_user`, one dummy probe) on a `LightmapGI`
  node and **renders a static quad lit entirely by it** — verified visually (bright HDR
  green, then a UV2 gradient proving atlas sampling). Run headless via the project's
  Godot 4.7 binary; render test runs windowed and screenshots to `poc/out/render.png`.
  Net: the externally-constructed-LightmapGIData approach is proven end-to-end.
- **M2a — DONE (2026-06-24).** `blender/bake_poc.py` headless-bakes a plane+cube+sun
  scene (Cycles, Diffuse, Direct+Indirect, **Color OFF** = irradiance, margin=16 EXTEND)
  to a linear `baked.exr` + `baked.json`. `poc/render_baked.gd` loads that real EXR into
  the proven harness and **renders it correctly** — white irradiance floor with the
  occluder's shadow and contact bounce intact (`poc/out/render_baked.png`). Confirms the
  Blender→Godot contract: irradiance (Color OFF), linear EXR, exposure=1, plausible
  brightness. Baked on Blender 4.1.1. (Denoise not yet applied — visible bake noise.)
- **M2b transport — DONE (2026-06-24).** Verified UV2 survives glTF round-trip
  Godot→Blender intact (`poc/export_gltf.gd` + `blender/inspect_gltf.py`: 2 UV layers,
  exact values). Then the full option-B chain: `poc/export_scene.gd` builds a Godot scene
  (floor w/ UV2 + cube occluder + sun) and exports `scene.glb`; `blender/bake.py` imports
  it and bakes irradiance into the floor's **UV2 layer** (`UVMap.001`); `render_baked.gd`
  renders the EXR back — floor lit with the occluder's shadow, originating from a Godot
  scene. Confirms Godot owns UV2, ships geometry+lights via glTF, Blender bakes into it.
- **M2c (1) denoise — DONE (2026-06-24).** `bake.py` runs a compositor OIDN Denoise pass
  over the baked image (EXR output stays linear scene-referred) and overwrites the EXR;
  noisy bake kept as fallback if denoise fails. Shadow grain gone (`render_baked.png`).
- **M2c (2) import flow — DONE (2026-06-24).** `poc/out/baked.exr.import`
  (`importer=2d_array_texture`, `type=CompressedTexture2DArray`) + Godot `--import`
  produces a real imported texture; `poc/render_imported.gd` loads it via `ResourceLoader`
  and feeds it straight to `set_lightmap_textures` — renders identically to the in-memory
  path. Note: an opaque (RGB) HDR EXR imports as **BPTC/BC6H** (`s3tc_bptc`), not RGBE9995
  (RGBE9995 was the RGBA-alpha case); both are valid HDR `TextureLayered`s.
- **M2c (3) multi-mesh — DONE (2026-06-24), via one-slice-per-mesh (no packing logic).**
  Blender doesn't auto-pack across objects and we bypass Godot's packer, but no packing
  code is needed: `bake.py` bakes each lightmap target (mesh with ≥2 UV layers) into its
  own denoised EXR slice (`baked_<i>.exr`); `render_multi.gd` loads them and calls
  `set_lightmap_textures([t0, t1, …])` — Godot **combines** them into one layered atlas
  (source: >1 texture → `create_from_images` of all layers). Each mesh records
  `slice_index = i`, identity `uv_scale`. Verified: Floor (slice 0, with shadow) and Roof
  (slice 1, uniformly lit) render as distinct slices (`render_multi.png`). True
  space-efficient sub-rect packing is a deferred *optimization* (Texture2DArray layers
  must share dimensions, so per-slice wastes space for many small/varied meshes).
- **M2c (4) light calibration — DEFERRED (parametrized).** `bake.py` exposes
  `SUN_ENERGY`/`AMBIENT`/`ATLAS`/`SAMPLES`. Matching Godot light energy → Cycles
  (empirical multiplier) and wiring Godot `WorldEnvironment` (sky/ambient) into the bake
  world are later features; defaults are fine until then.
- **M2c (5) EditorPlugin — DONE (2026-06-24).** `addons/pavlaka/` (`plugin.cfg`,
  `plugin.gd`, `baker.gd`): a "Bake with Blender" button. `PavlakaBaker.bake(root, lm,
  blender_path, opts)` gathers static `MeshInstance3D`s with UV2 → exports glb → runs
  Blender (`OS.execute`, params passed through) → writes `.import` + `reimport_files`
  per slice → builds `LightmapGIData` (`add_user` per mesh, per-slice) → saves `.lmbake`
  → assigns to the `LightmapGI` node. Verified end-to-end via a headless `_autobake`
  self-test + a windowed render of the produced scene: floor lit purely by the baked
  lightmap, cube shadow intact.
- **Two real findings from building the plugin:**
  - **Bake must run in the GUI editor, not `--headless`.** `LightmapGIData` serializes
    probe `points`/`sh` by querying the RenderingServer (`get_capture_points` →
    `RS::lightmap_get_probe_capture_points`, `lightmap_gi.cpp:259`), and the headless
    dummy renderer returns empty. Empty points on reload → `set_capture_data` discards
    bounds → lightmap instance culled → renders unlit (pitfall 6 again, via the
    save/reload path). Under the real editor RS the points round-trip and it works. So
    the plugin's bake is a GUI-editor action; a pure-CI/headless bake would need a
    different probe-data persistence path.
  - **Disable (or bake-mode) the static lights after baking.** A `DirectionalLight3D`
    left active double-lights static geometry in real time (and with shadows off, washes
    out the baked shadow). The verify scene disables real-time lights so only the
    lightmap contributes; the plugin should eventually manage this for the user.
- **glTF export pitfall — hidden nodes + KHR_node_visibility (found in real use).**
  Godot 4.7's glTF exporter emits a *required* `KHR_node_visibility` extension whenever
  any exported node has `visible == false` (`gltf_document.cpp:396`). Older Blender glTF
  importers (e.g. 4.1) reject required extensions they don't know, failing the whole
  import with `RuntimeError: Extension KHR_node_visibility is not available`. Common
  trigger: hidden source CSG nodes left after "Bake Mesh Instance". Fix: the baker
  exports a duplicate of the scene with non-visible `Node3D`s pruned (`_prune_hidden`) —
  which also matches the rule that hidden meshes shouldn't bake — so no hidden node is
  exported and the extension is never emitted. (Alternative would be a newer Blender.)
- **Remaining polish (all optional):** light double-count handling, energy calibration,
  `WorldEnvironment` wiring, space-efficient atlas packing, a settings UI (Blender path /
  resolution / samples), and the option-A path (Blender owns UV2).

## Revised POC Milestones

- **M0+M1 (merged):** GDScript-only. Build a `LightmapGIData` in memory from a
  hand-made EXR atlas + one `add_user`, `ResourceSaver.save()` to `.lmbake`, wire to a
  `LightmapGI` node, confirm one static mesh renders. Proves construction + render +
  serialization with zero Blender plumbing. Cheapest go/no-go.
- **M2:** Headless Blender Cycles bake (raw linear EXR, margin + dilate + OIDN) →
  EXR + metadata JSON → plugin assembles the M1 resource. Proves the full pipeline.

---

# Bake Correctness & Light Matching (Godot 4.7 source-verified)

These answer what Blender must produce so the result matches Godot's own lighting.

## What the lightmap stores: IRRADIANCE, not radiance

Godot stores **incoming light only**; albedo is applied at runtime. The shader adds
the raw lightmap sample into `ambient_light`, then `ambient_light *= albedo.rgb`
(`scene_forward_clustered.glsl:1869` then `:2185`; mobile identical). The bake compute
shader stores `accum_light` with no receiver-albedo multiply
(`lm_compute.glsl:971-972`). Storing radiance would double-apply albedo.

**Blender bake settings:** Bake type **Diffuse**, contributions **Direct + Indirect**,
**Color OFF** (Color off excludes the surface's own base color = irradiance). Do NOT
use the Combined pass. Output linear/HDR EXR. Leave emission out (Godot bakes/applies
emission via its own separate emission texture). The Godot meshes still need their
albedo materials assigned — the lightmap supplies only the light.

## Plugin import mechanics (script-callable)

`ResourceLoader::import` is not script-bound; drive `EditorFileSystem` instead:

```gdscript
# after writing <atlas>.exr and <atlas>.exr.import to disk:
var efs := EditorInterface.get_resource_filesystem()
efs.update_file(atlas_path)            # editor_file_system.cpp:3718 (bound)
efs.reimport_files([atlas_path])       # editor_file_system.cpp:3721 (bound); not re-entrant
var tex := ResourceLoader.load(atlas_path) as Texture2DArray
```

`.import` contents (from the engine's own baker, `lightmap_gi.cpp:872-881`):

```ini
[remap]
importer="2d_array_texture"
type="CompressedTexture2DArray"
[params]
compress/mode=2
compress/channel_pack=1
mipmaps/generate=false
slices/horizontal=1
slices/vertical=<slice count>   ; slices stacked vertically in the EXR
```

## UV2-preservation switch (the A/B import lever)

Scene import enum **`meshes/light_baking`** (`resource_importer_scene.cpp:2623`):
`0=Disabled, 1=Static (default), 2=Static Lightmaps, 3=Dynamic`.
- Only value **`2`** runs xatlas, and when it does it **always** `clear()`s and
  overwrites UV2 — no "skip if present" path (`importer_mesh.cpp:1502`).
- **Option A (Blender owns UV2):** keep `=1` — mesh is marked STATIC *and* authored
  UV2 passes through untouched.
- **Option B (Godot owns UV2):** set `=2` to get xatlas unwrap, then export to Blender.
- `meshes/lightmap_texel_size` does NOT gate this; it only sets density when unwrap runs.

## Light & environment matching — the main remaining risk

We are **replacing** Godot's lightmapper, not reproducing it. The consistency target is
Godot's **real-time light falloff**, so a baked static surface and a dynamically-lit
object under the same lamp agree. Godot's lightmapper mirrors the real-time renderer,
so it is the reference.

Conversions Godot applies before baking (`lightmap_gi.cpp:1371-1414`):
- Light color: **sRGB → linear** (`srgb_to_linear()`). Feed Cycles already-linear color.
- `light_energy` (`PARAM_ENERGY`): dimensionless multiplier on `color * attenuation`
  (`lm_compute.glsl:705`) — **not watts**. No universal constant vs Cycles; calibrate
  empirically (bake one light, compare a texel).
- `light_indirect_energy`: per-light multiplier on bounce contribution only. Cycles has
  no equivalent — flag if ≠ 1.
- Physical units off + no CameraAttributes ⇒ `exposure_normalization = 1.0`. Keep it
  this way for a matched bake (see exposure section above).

**Falloff model mismatch (point/spot) — genuine and unavoidable natively:**
- Godot omni/spot: `max(1 − (d/range)⁴, 0)² · d^(−attenuation)` with a hard cutoff at
  `range` (`lm_compute.glsl:397-404, 501`); default `attenuation = 1` is inverse-
  *distance*, not inverse-square.
- Cycles: physically-correct inverse-*square*, no range cutoff.
- Setting Godot `attenuation = 2` matches only the `d⁻²` term; the `(1−(d/range)⁴)²`
  window near the range edge has no Cycles analogue.
- Mitigations: (1) **directional/sun lights match exactly** — no distance term, so a
  sun-lit POC sidesteps this entirely; (2) replicate Godot's curve with Blender Light
  Falloff + math nodes (fiddly); (3) accept minor static-vs-dynamic divergence near
  light edges.

Spot cone: Blender "Size" (full cone) = **2× Godot `spot_angle`** (half-cone).
Directional `light_angular_distance`(°) → `tan(deg2rad(angle))` soft-shadow disk —
approximate, check for factor-of-2.

**Environment** (`lightmap_gi.cpp:1424-1466`): baked to a 128×64 equirect panorama
(scene sky, custom sky, or flat `custom_color × custom_energy`), sampled on escaped
bounce rays, and is **NOT** exposure-normalized (unlike direct/emissive). Match it with
a Blender world environment texture / background color in linear space; if you scale the
whole bake by an exposure factor, the environment contribution will be wrong relative to
Godot.
