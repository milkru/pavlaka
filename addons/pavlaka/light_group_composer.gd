@tool
class_name PavlakaGroupComposer
extends RefCounted
## Adds light groups to a lightmap on the GPU (Forward+ and Mobile: the RenderingDevice).
## The lightmap Godot draws becomes a texture array of ours: [lightmap pages..., main bake
## pages...], at the bake's page size (the imported pages may be scaled: compressed ones are
## resized to a power of two). A compute shader first copies the main bake into both halves; each
## update() then writes main bake + sum(group energy x group light) into every tile a group
## lights. Godot's own lightmap drawing is untouched: RenderingServer.lightmap_set_textures points
## it at our array. All RenderingDevice work runs on the render thread.

const COPY := """
#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2DArray page_tex;
layout(set = 0, binding = 1, rgba16f) uniform restrict writeonly image2DArray lightmap;
layout(push_constant, std430) uniform Params { ivec4 p; } params; // page, pages
void main() {
	ivec2 c = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(lightmap).xy;
	if (c.x >= size.x || c.y >= size.y) {
		return;
	}
	// sampled where the lightmap's UVs sample it: the page may be stored at another size
	vec4 v = textureLod(page_tex, vec3((vec2(c) + 0.5) / vec2(size), 0.0), 0.0);
	imageStore(lightmap, ivec3(c, params.p.x), v);
	imageStore(lightmap, ivec3(c, params.p.x + params.p.y), v);
}
"""

const COMPOSE := """
#version 450
layout(local_size_x = %d, local_size_y = %d, local_size_z = 1) in;
layout(set = 0, binding = 0, rgba16f) uniform restrict image2DArray lightmap;
layout(set = 0, binding = 1) uniform sampler2DArray tiles;
layout(set = 0, binding = 2, std430) restrict readonly buffer Cells { int c[]; } cells;
layout(set = 0, binding = 3, std430) restrict readonly buffer Parts { int p[]; } parts;
layout(set = 0, binding = 4, std430) restrict readonly buffer Energy { float e[]; } energy;
layout(push_constant, std430) uniform Params { ivec4 p; } params; // cells, pages, row
void main() {
	int cell = int(gl_WorkGroupID.y) * params.p.z + int(gl_WorkGroupID.x);
	if (cell >= params.p.x) {
		return;
	}
	int b = cell * 7;
	ivec2 t = ivec2(gl_LocalInvocationID.xy);
	if (t.x >= cells.c[b + 3] || t.y >= cells.c[b + 4]) {
		return;
	}
	int page = cells.c[b];
	ivec2 at = ivec2(cells.c[b + 1], cells.c[b + 2]) + t;
	vec4 v = imageLoad(lightmap, ivec3(at, page + params.p.y)); // the main bake
	int first = cells.c[b + 5];
	for (int i = 0; i < cells.c[b + 6]; i++) {
		int q = (first + i) * 3;
		vec3 light = texelFetch(tiles, ivec3(ivec2(parts.p[q + 1], parts.p[q + 2]) + t, 0), 0).rgb;
		v.rgb += energy.e[parts.p[q]] * light;
	}
	imageStore(lightmap, ivec3(at, page), v);
}
"""

const ROW := 65535 # most workgroups in one dispatch dimension

## The composers showing on each lightmap (its RID's id -> [[composer id, its texture]...], the
## last one shown): two nodes may share one LightmapGIData (a duplicated node, a map loaded twice).
static var _bound := {}

var _rd: RenderingDevice
var _id := 0               # this composer's instance id (PREDELETE can't ask for it)
var _lightmap := RID()     # RenderingServer: the LightmapGIData's lightmap
var _sh := false           # the light data uses spherical harmonics
var _out := RID()          # RenderingDevice: our texture array
var _out_tex := RID()      # RenderingServer: a texture over it, for the lightmap
var _rids: Array[RID] = [] # RenderingDevice objects to free (last made first freed)
var _compose := RID()
var _compose_set := RID()
var _energy := RID()
var _cells := 0
var _pages := 0
var _running := false
var _data: LightmapGIData  # whose lightmap we replaced, given back if we are dropped unstopped
var _groups: PavlakaLightGroups  # held until our GPU objects are freed: its tiles are in our uniform set


## Points `data`'s lightmap at a composed copy with `groups` added. Returns false when it can't
## (no RenderingDevice, or the data has no pages).
func start(data: LightmapGIData, groups: PavlakaLightGroups, energies: PackedFloat32Array) -> bool:
	if RenderingServer.get_rendering_device() == null or data == null or groups == null:
		return false
	var pages: Array = data.get_lightmap_textures()
	if pages.is_empty():
		return false
	var page_rids: Array[RID] = []
	var size := groups.page_size
	for p in pages:
		var t := p as TextureLayered
		if t == null:
			return false
		page_rids.append(t.get_rid())
	var tiles_rid: RID = groups.tiles.get_rid() if groups.tiles else RID()
	_data = data
	_groups = groups
	_id = get_instance_id()
	_lightmap = data.get_rid()
	_sh = data.is_using_spherical_harmonics()
	_pages = pages.size()
	@warning_ignore("integer_division")
	_cells = groups.cells.size() / 7
	_running = true
	# `self` bound: this object stays alive until the render thread has run it
	RenderingServer.call_on_render_thread(_start.bind(page_rids, size, tiles_rid, groups.cells,
		groups.parts, energies, self))
	return true


## Writes the lightmap with each group at its energy (index = group index).
func update(energies: PackedFloat32Array) -> void:
	if _running and _cells > 0:
		RenderingServer.call_on_render_thread(_update.bind(energies, self))


## Gives the light data its own pages back (or another composer's, if one shares it) and frees ours.
func stop() -> void:
	if not _running:
		return
	_running = false
	# on the render thread, after _start: by then everything it made is in the members
	RenderingServer.call_on_render_thread(PavlakaGroupComposer._stop.bind(self))


static func _stop(c: PavlakaGroupComposer) -> void:
	PavlakaGroupComposer._release(c._data, c._lightmap, c._id, c._sh)
	PavlakaGroupComposer._free_rids(c._out_tex, c._rids, c._groups)
	c._data = null
	c._groups = null
	c._rids = []
	c._out_tex = RID()
	c._compose = RID()
	c._compose_set = RID()
	c._energy = RID()


# Dropped without stop() (a tool script reloaded): don't leak the GPU objects. During PREDELETE an
# object can't call its own methods, so the cleanup is static and takes the members.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _running:
		PavlakaGroupComposer._release(_data, _lightmap, _id, _sh)
		RenderingServer.call_on_render_thread(PavlakaGroupComposer._free_rids.bind(_out_tex, _rids.duplicate(), _groups))


# This composer's texture off the lightmap: the one shown before it comes back, or, if none is
# left, the light data's own pages.
static func _release(data: LightmapGIData, lightmap: RID, id: int, sh: bool) -> void:
	var key := lightmap.get_id()
	var list: Array = _bound.get(key, [])
	var shown: bool = list.is_empty() or list[-1][0] == id
	list = list.filter(func(e: Array) -> bool: return e[0] != id)
	if list.is_empty():
		_bound.erase(key)
	else:
		_bound[key] = list
	if not shown:
		return
	if list.is_empty():
		_give_back(data)
	else:
		RenderingServer.lightmap_set_textures(lightmap, list[-1][1], sh)


# The light data's lightmap back on its own pages.
static func _give_back(data: LightmapGIData) -> void:
	if data == null:
		return
	var pages: Array = data.get_lightmap_textures()
	if pages.size() == 1:
		RenderingServer.lightmap_set_textures(data.get_rid(), (pages[0] as Texture).get_rid(),
			data.is_using_spherical_harmonics())
	else:
		data.set_lightmap_textures(pages) # combines the pages again


func _start(page_rids: Array[RID], size: Vector2i, tiles_rid: RID, cells: PackedInt32Array,
		parts: PackedInt32Array, energies: PackedFloat32Array, _alive: Object) -> void:
	_rd = RenderingServer.get_rendering_device()
	var fmt := RDTextureFormat.new()
	fmt.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	fmt.width = size.x
	fmt.height = size.y
	fmt.array_layers = 2 * page_rids.size() # also: Godot takes an RD array of 2 layers or more
	fmt.usage_bits = (RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT)
	_out = _keep(_rd.texture_create(fmt, RDTextureView.new()))
	var sampler := _keep(_rd.sampler_create(RDSamplerState.new()))  # nearest: the tiles
	var linear_state := RDSamplerState.new()  # the main bake's pages, which may be scaled
	linear_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	linear_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	var linear := _keep(_rd.sampler_create(linear_state))
	# copy the main bake into both halves
	var copy_shader := _shader(COPY)
	var copy := _keep(_rd.compute_pipeline_create(copy_shader))
	# everything made before the compute list opens: only binds and dispatches run inside it
	var sets: Array[RID] = []
	for i in page_rids.size():
		var src := RenderingServer.texture_get_rd_texture(page_rids[i])
		sets.append(_rd.uniform_set_create([_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, [linear, src]),
			_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 1, [_out])], copy_shader, 0))
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, copy)
	for i in page_rids.size():
		_rd.compute_list_bind_uniform_set(cl, sets[i], 0)
		var pc := PackedInt32Array([i, page_rids.size(), 0, 0]).to_byte_array()
		_rd.compute_list_set_push_constant(cl, pc, pc.size())
		@warning_ignore("integer_division")
		_rd.compute_list_dispatch(cl, (size.x + 7) / 8, (size.y + 7) / 8, 1)
	_rd.compute_list_end()
	# the groups
	if _cells > 0 and tiles_rid.is_valid():
		var shader := _shader(COMPOSE % [PavlakaLightGroups.TILE, PavlakaLightGroups.TILE])
		_compose = _keep(_rd.compute_pipeline_create(shader))
		var cells_buf := _keep(_rd.storage_buffer_create(cells.size() * 4, cells.to_byte_array()))
		var parts_buf := _keep(_rd.storage_buffer_create(maxi(parts.size(), 1) * 4,
			parts.to_byte_array() if parts.size() else PackedByteArray([0, 0, 0, 0])))
		_energy = _keep(_rd.storage_buffer_create(maxi(energies.size(), 1) * 4, _energy_bytes(energies)))
		_compose_set = _keep(_rd.uniform_set_create([
			_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 0, [_out]),
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1,
				[sampler, RenderingServer.texture_get_rd_texture(tiles_rid)]),
			_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 2, [cells_buf]),
			_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 3, [parts_buf]),
			_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 4, [_energy])], shader, 0))
		_dispatch()
	_out_tex = RenderingServer.texture_rd_create(_out, RenderingServer.TEXTURE_LAYERED_2D_ARRAY)
	RenderingServer.lightmap_set_textures(_lightmap, _out_tex, _sh)
	var key := _lightmap.get_id()
	if not _bound.has(key):
		_bound[key] = []
	_bound[key].append([_id, _out_tex])


func _update(energies: PackedFloat32Array, _alive: Object) -> void:
	if not _energy.is_valid():
		return
	var bytes := _energy_bytes(energies)
	_rd.buffer_update(_energy, 0, bytes.size(), bytes)
	_dispatch()


func _dispatch() -> void:
	var pc := PackedInt32Array([_cells, _pages, ROW, 0]).to_byte_array()
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _compose)
	_rd.compute_list_bind_uniform_set(cl, _compose_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	@warning_ignore("integer_division")
	_rd.compute_list_dispatch(cl, mini(_cells, ROW), (_cells + ROW - 1) / ROW, 1)
	_rd.compute_list_end()


static func _free_rids(out_tex: RID, rids: Array, _groups_alive: Resource = null) -> void:
	if out_tex.is_valid():
		RenderingServer.free_rid(out_tex) # its view of our texture; ours goes below
	var rd := RenderingServer.get_rendering_device()
	for i in range(rids.size() - 1, -1, -1): # dependents first; a uniform set we don't keep
		rd.free_rid(rids[i])                   # goes with the texture or sampler it uses


func _keep(rid: RID) -> RID:
	if rid.is_valid():
		_rids.append(rid)
	return rid


func _shader(source: String) -> RID:
	var src := RDShaderSource.new()
	src.source_compute = source
	var spirv := _rd.shader_compile_spirv_from_source(src)
	if spirv.compile_error_compute != "":
		push_error("pavlaka: light group shader: %s" % spirv.compile_error_compute)
	return _keep(_rd.shader_create_from_spirv(spirv))


func _uniform(type: int, binding: int, ids: Array) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = type
	u.binding = binding
	for id in ids:
		u.add_id(id)
	return u


static func _energy_bytes(energies: PackedFloat32Array) -> PackedByteArray:
	return energies.to_byte_array() if energies.size() else PackedByteArray([0, 0, 0, 0])
