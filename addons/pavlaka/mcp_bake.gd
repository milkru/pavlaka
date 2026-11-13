@tool
extends RefCounted
## godot-ai custom tool "pavlaka_bake" (registered by plugin.gd when godot-ai is installed).
## Replies after the bake (deferred), so the MCP call returns the result.


func bake(params: Dictionary, ctx: Object) -> Dictionary:
	var plugin: Object = Engine.get_meta("pavlaka_plugin", null)
	if plugin == null:
		return {"status": "error", "error": {"code": "NOT_ENABLED", "message": "the pavlaka plugin is not enabled"}}
	plugin.call_deferred("mcp_bake", str(params.get("scene", "")), ctx)
	return {"_deferred": true}
