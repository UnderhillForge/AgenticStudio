class_name AgenticStudioPolicy
extends RefCounted
## Auto-approve table enforced in the plugin before undo-redo / commit_action.
## Model id does not change the table.

const DECISION_ALLOW: String = "allow"
const DECISION_CONFIRM: String = "confirm"
const DECISION_REJECT: String = "reject"

const META_PAGE: String = "agentic_page"


static func classify(tool_name: String, args: Dictionary) -> String:
	## Returns allow | confirm | reject. Reject is for unknown/dangerous shapes.
	var name: String = tool_name.strip_edges()
	match name:
		"add_node":
			# Allow add_child under the edited scene root only (tool always parents to root).
			return DECISION_ALLOW
		"set_property":
			var prop: String = str(args.get("property", "")).strip_edges()
			if prop == "script":
				return DECISION_CONFIRM
			# Property set on an existing node — caller still verifies the node exists.
			return DECISION_ALLOW
		"write_file":
			var path: String = str(args.get("path", "")).strip_edges().to_lower()
			if path.ends_with(".gd") or path.ends_with(".cs"):
				return DECISION_CONFIRM
			if path.ends_with("project.godot") or path.find("project.godot") >= 0:
				return DECISION_CONFIRM
			if path.ends_with(".tscn") or path.ends_with(".scn"):
				return DECISION_CONFIRM
			return DECISION_CONFIRM
		"delete_file":
			return DECISION_CONFIRM
		"create_asset":
			# Instances under root; treat as allow for the scene half (page data is separate).
			return DECISION_ALLOW
		"link":
			# Page-only; not a scene write. Allow without scene confirm.
			return DECISION_ALLOW
		# New allow reads
		"scene_hierarchy", "node_properties", "signal_list", "resource_find", \
		"input_map_list", "log_read", "editor_screenshot":
			return DECISION_ALLOW
		# New allow writes (page_id required by tools; parent under scene root)
		"node_duplicate", "node_rename", "node_reparent", "node_move", \
		"signal_connect", "resource_assign":
			return DECISION_ALLOW
		# Always confirm — never auto-approve
		"script_patch", "script_attach", "input_map_ensure":
			return DECISION_CONFIRM
		"play_scene", "read_scene", "list_pages", "get_page", "list_dir", "read_file", "screenshot", "check_page_drift":
			return DECISION_ALLOW
		_:
			# project.godot / autoload / rename-style unknowns
			var lower: String = name.to_lower().replace("-", "_")
			if lower.find("autoload") >= 0 or lower.find("project") >= 0:
				return DECISION_CONFIRM
			if lower.find("delete") >= 0 or lower.find("remove") >= 0:
				return DECISION_CONFIRM
			return DECISION_REJECT


static func needs_confirm(tool_name: String, args: Dictionary) -> bool:
	return classify(tool_name, args) == DECISION_CONFIRM


static func is_allowed_unattended(tool_name: String, args: Dictionary) -> bool:
	## Auto-approve and sidecar unattended path: only ALLOW proceeds without asking.
	return classify(tool_name, args) == DECISION_ALLOW


static func should_ask(tool_name: String, args: Dictionary, ask_writes: bool) -> bool:
	## ask_writes true = Run mode (ask on writes). Auto-approve uses ask_writes false
	## but still asks for CONFIRM-class ops. Model id is ignored.
	var decision: String = classify(tool_name, args)
	if decision == DECISION_CONFIRM:
		return true
	if decision == DECISION_REJECT:
		return true
	if ask_writes and _is_write_like(tool_name):
		return true
	return false


static func _is_write_like(tool_name: String) -> bool:
	match tool_name:
		"add_node", "set_property", "link", "create_asset", "write_file", "delete_file", \
		"node_duplicate", "node_rename", "node_reparent", "node_move", \
		"signal_connect", "resource_assign", \
		"script_patch", "script_attach", "input_map_ensure":
			return true
		_:
			return false


static func reject_message(tool_name: String, args: Dictionary) -> String:
	var decision: String = classify(tool_name, args)
	if decision == DECISION_REJECT:
		return "blocked by policy — confirm later"
	if decision == DECISION_CONFIRM:
		return "needs confirm — %s" % tool_name
	return ""
