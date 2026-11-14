@tool
extends RefCounted
## godot-ai custom tools "pavlaka_bake" and "pavlaka_bake_status" (registered by plugin.gd when
## godot-ai is installed). pavlaka_bake replies after the bake (deferred), so the MCP call returns
## the result; a bake longer than godot-ai's time limit replies {running: true} first.


func bake(params: Dictionary, ctx: Object) -> Dictionary:
	var plugin: Object = Engine.get_meta("pavlaka_plugin", null)
	if plugin == null:
		return _not_enabled()
	plugin.call_deferred("mcp_bake", str(params.get("scene", "")), ctx)
	return {"_deferred": true}


func status(_params: Dictionary, _ctx: Object) -> Dictionary:
	var plugin: Object = Engine.get_meta("pavlaka_plugin", null)
	if plugin == null:
		return _not_enabled()
	return {"data": plugin.bake_status()}


## godot-ai asks before it swaps scripts (its hot update): not while a bake runs.
func quiesce_for_script_swap() -> Dictionary:
	var plugin: Object = Engine.get_meta("pavlaka_plugin", null)
	return {"ok": plugin == null or not plugin.bake_status().get("running", false)}


func _not_enabled() -> Dictionary:
	return {"status": "error", "error": {"code": "NOT_ENABLED", "message": "the pavlaka plugin is not enabled"}}
