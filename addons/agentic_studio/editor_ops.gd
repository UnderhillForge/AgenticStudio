class_name AgenticStudioEditorOps
extends RefCounted
## Extra editor read/write ops. Scene/resource writes require page_id (checked by caller).
## Kept alive for UndoRedo do/undo methods. Never scrapes the Output panel.

const META_PAGE: String = "agentic_page"
const LOG_TAIL_CAP: int = 200
const HIERARCHY_DEFAULT_LIMIT: int = 100
const EDITOR_SHOT_SUBDIR: String = "editor_shots"
const PLAY_FRAME_PATH: String = "user://agentic/last_frame.png"

## Owner SceneTools instance (weak-ish RefCounted ref) for _ensure_action / _note_write.
var _tools: RefCounted = null


func bind_tools(tools: RefCounted) -> void:
	_tools = tools


func tool_definitions() -> Array:
	var out: Array = []
	out.append_array(_read_tool_definitions())
	out.append_array(_write_allow_tool_definitions())
	out.append_array(_write_confirm_tool_definitions())
	return out


func plan_tool_definitions() -> Array:
	## Plan stays read-only: only the new read ops (no writes).
	return _read_tool_definitions()


static func is_read_tool(tool_name: String) -> bool:
	match tool_name:
		"scene_hierarchy", "node_properties", "signal_list", "resource_find", \
		"input_map_list", "log_read", "editor_screenshot":
			return true
		_:
			return false


static func is_write_tool(tool_name: String) -> bool:
	match tool_name:
		"node_duplicate", "node_rename", "node_reparent", "node_move", \
		"signal_connect", "resource_assign", \
		"script_patch", "script_attach", "input_map_ensure":
			return true
		_:
			return false


static func is_scene_write_tool(tool_name: String) -> bool:
	## Triggers play gate / page_id. input_map_ensure writes project.godot (confirm) but is not a scene write.
	match tool_name:
		"node_duplicate", "node_rename", "node_reparent", "node_move", \
		"signal_connect", "resource_assign", "script_patch", "script_attach":
			return true
		_:
			return false


static func requires_page_id(tool_name: String) -> bool:
	return is_scene_write_tool(tool_name)


func execute(tool_name: String, args: Dictionary) -> Dictionary:
	match tool_name:
		"scene_hierarchy":
			return scene_hierarchy(args)
		"node_properties":
			return node_properties(args)
		"signal_list":
			return signal_list(args)
		"resource_find":
			return resource_find(args)
		"input_map_list":
			return input_map_list(args)
		"log_read":
			return log_read(args)
		"node_duplicate":
			return node_duplicate(args)
		"node_rename":
			return node_rename(args)
		"node_reparent":
			return node_reparent(args)
		"node_move":
			return node_move(args)
		"signal_connect":
			return signal_connect(args)
		"resource_assign":
			return resource_assign(args)
		"script_patch":
			return script_patch(args)
		"script_attach":
			return script_attach(args)
		"input_map_ensure":
			return input_map_ensure(args)
		_:
			return _fail(tool_name, "unknown editor op")


# --- Read ops -----------------------------------------------------------------

func scene_hierarchy(args: Dictionary) -> Dictionary:
	var root: Node = _edited_root()
	if root == null:
		return _fail("scene_hierarchy", "no open scene")
	var depth: int = maxi(0, int(args.get("depth", 8)))
	var offset: int = maxi(0, int(args.get("offset", 0)))
	var limit: int = clampi(int(args.get("limit", HIERARCHY_DEFAULT_LIMIT)), 1, 500)
	var flat: Array = []
	_walk_hierarchy(root, root, 0, depth, flat)
	var total: int = flat.size()
	var slice: Array = []
	var end: int = mini(offset + limit, total)
	for i: int in range(offset, end):
		slice.append(flat[i])
	var payload: Dictionary = {
		"ok": true,
		"root": str(root.name),
		"path": str(root.scene_file_path),
		"offset": offset,
		"limit": limit,
		"depth": depth,
		"total": total,
		"nodes": slice,
	}
	return _ok("scene_hierarchy", payload, "scene_hierarchy ok nodes=%d/%d" % [slice.size(), total])


func node_properties(args: Dictionary) -> Dictionary:
	var path: String = str(args.get("path", "")).strip_edges()
	if path.is_empty():
		return _fail("node_properties", "path is required")
	var node: Node = _resolve_node(path)
	if node == null:
		return _fail("node_properties", "node not found: %s" % path)
	var props: Dictionary = {}
	for info: Dictionary in node.get_property_list():
		var pname: String = str(info.get("name", ""))
		if pname.is_empty():
			continue
		var usage: int = int(info.get("usage", 0))
		if (usage & PROPERTY_USAGE_CATEGORY) != 0:
			continue
		if (usage & PROPERTY_USAGE_GROUP) != 0:
			continue
		if (usage & PROPERTY_USAGE_SUBGROUP) != 0:
			continue
		if (usage & PROPERTY_USAGE_STORAGE) == 0 and (usage & PROPERTY_USAGE_EDITOR) == 0:
			continue
		props[pname] = _serialize_value(node.get(pname))
	var payload: Dictionary = {
		"ok": true,
		"path": path,
		"type": node.get_class(),
		"name": str(node.name),
		"properties": props,
	}
	return _ok("node_properties", payload, "node_properties ok path=%s props=%d" % [path, props.size()])


func signal_list(args: Dictionary) -> Dictionary:
	var path: String = str(args.get("path", "")).strip_edges()
	if path.is_empty():
		return _fail("signal_list", "path is required")
	var node: Node = _resolve_node(path)
	if node == null:
		return _fail("signal_list", "node not found: %s" % path)
	var signals_out: Array = []
	for sig: Dictionary in node.get_signal_list():
		var sname: String = str(sig.get("name", ""))
		var conns: Array = []
		for c: Dictionary in node.get_signal_connection_list(StringName(sname)):
			var target: Object = c.get("callable", Callable()).get_object() if c.has("callable") else c.get("target")
			var method: String = ""
			if c.has("callable") and c.get("callable") is Callable:
				method = str((c.get("callable") as Callable).get_method())
			elif c.has("method"):
				method = str(c.get("method", ""))
			var target_path: String = ""
			if target is Node:
				target_path = _path_from_root(target as Node)
			conns.append({
				"target": target_path,
				"method": method,
				"flags": int(c.get("flags", 0)),
			})
		signals_out.append({
			"name": sname,
			"args": sig.get("args", []),
			"connections": conns,
		})
	var payload: Dictionary = {
		"ok": true,
		"path": path,
		"type": node.get_class(),
		"signals": signals_out,
	}
	return _ok("signal_list", payload, "signal_list ok path=%s signals=%d" % [path, signals_out.size()])


func resource_find(args: Dictionary) -> Dictionary:
	var type_name: String = str(args.get("type", args.get("class", ""))).strip_edges()
	var name_query: String = str(args.get("name", "")).strip_edges().to_lower()
	var limit: int = clampi(int(args.get("limit", 50)), 1, 200)
	var matches: Array = []
	_scan_resources("res://", type_name, name_query, matches, limit)
	var payload: Dictionary = {
		"ok": true,
		"type": type_name,
		"name": name_query,
		"paths": matches,
		"count": matches.size(),
	}
	return _ok("resource_find", payload, "resource_find ok count=%d" % matches.size())


func input_map_list(_args: Dictionary) -> Dictionary:
	## Read project input/* from ProjectSettings (editor InputMap is the editor's own map).
	var actions: Array = []
	for prop: Dictionary in ProjectSettings.get_property_list():
		var key: String = str(prop.get("name", ""))
		if not key.begins_with("input/"):
			continue
		var action: String = key.substr(6)
		if action.is_empty():
			continue
		var raw: Variant = ProjectSettings.get_setting(key)
		var events_summary: Array = []
		var deadzone: float = 0.5
		if typeof(raw) == TYPE_DICTIONARY:
			var d: Dictionary = raw
			deadzone = float(d.get("deadzone", 0.5))
			var evs: Variant = d.get("events", [])
			if typeof(evs) == TYPE_ARRAY:
				for ev: Variant in evs:
					events_summary.append(_summarize_input_event(ev))
		actions.append({
			"action": action,
			"deadzone": deadzone,
			"events": events_summary,
		})
	actions.sort_custom(func(a: Variant, b: Variant) -> bool:
		return str((a as Dictionary).get("action", "")) < str((b as Dictionary).get("action", ""))
	)
	var payload: Dictionary = {"ok": true, "actions": actions, "count": actions.size()}
	return _ok("input_map_list", payload, "input_map_list ok count=%d" % actions.size())


func log_read(args: Dictionary) -> Dictionary:
	## plugin / game / editor tails. Cap. Never scrape the Output panel.
	var which: String = str(args.get("source", args.get("which", "plugin"))).strip_edges().to_lower()
	var max_lines: int = clampi(int(args.get("limit", LOG_TAIL_CAP)), 1, LOG_TAIL_CAP)
	var session_id: String = str(args.get("session_id", "studio")).strip_edges()
	var lines: PackedStringArray = PackedStringArray()
	var path: String = ""
	match which:
		"plugin", "session":
			path = AgenticStudioConfig.LOGS_DIR.path_join("%s.log" % session_id.replace("/", "_"))
			lines = _tail_file(path, max_lines)
		"game", "play":
			path = "user://agentic/last_play.json"
			lines = _tail_file(path, max_lines)
		"editor":
			path = _editor_log_path()
			if path.is_empty():
				return _fail("log_read", "editor log path not found")
			lines = _tail_abs_file(path, max_lines)
		_:
			return _fail("log_read", "source must be plugin, game, or editor")
	var payload: Dictionary = {
		"ok": true,
		"source": which,
		"path": path,
		"lines": Array(lines),
		"count": lines.size(),
	}
	return _ok("log_read", payload, "log_read ok source=%s lines=%d" % [which, lines.size()])


func execute_editor_screenshot(session_id: String) -> Dictionary:
	## Async: capture open editor screen (3D preferred, else 2D). Distinct from play frame.
	var target: String = "editor_3d"
	var main: VBoxContainer = EditorInterface.get_editor_main_screen()
	if main != null:
		# Heuristic: if 2D viewport is the visible editor screen name.
		var screen_name: String = str(main.name).to_lower()
		if screen_name.find("2d") >= 0:
			target = "editor_2d"
	# Prefer 3D unless 2D is clearly active via EditorInterface helper if present.
	if EditorInterface.has_method("get_editor_viewport_2d") and EditorInterface.has_method("get_editor_viewport_3d"):
		# Keep default 3D; callers can still use screenshot for explicit target.
		pass
	var shot = AgenticStudioScreenshotSupport.new()
	# Capture into editor_shots/ so path differs from user://agentic/last_frame.png
	var captured: Dictionary
	if target == "editor_2d":
		captured = await shot.capture(session_id, "editor_2d")
	else:
		captured = await shot.capture(session_id, "editor_3d")
	if not bool(captured.get("ok", false)):
		return {
			"ok": false,
			"blocked": false,
			"skipped": false,
			"wrote": false,
			"error": str(captured.get("error", "editor_screenshot failed")),
			"log": str(captured.get("log", "editor_screenshot failed")),
			"result": {"ok": false, "error": str(captured.get("error", ""))},
		}
	# Re-home under editor_shots/ with a distinct name if still under shots/.
	var src_path: String = str(captured.get("path", ""))
	var dest_dir: String = AgenticStudioConfig.LOGS_DIR.path_join(EDITOR_SHOT_SUBDIR)
	var abs_dest_dir: String = ProjectSettings.globalize_path(dest_dir)
	if not DirAccess.dir_exists_absolute(abs_dest_dir):
		DirAccess.make_dir_recursive_absolute(abs_dest_dir)
	var dest_path: String = dest_dir.path_join(
		"editor_%d_%s.png" % [Time.get_unix_time_from_system(), target]
	)
	var abs_src: String = ProjectSettings.globalize_path(src_path)
	var abs_dest: String = ProjectSettings.globalize_path(dest_path)
	if FileAccess.file_exists(abs_src):
		var img := Image.new()
		var load_err: Error = img.load(abs_src)
		if load_err == OK:
			img.save_png(abs_dest)
			DirAccess.remove_absolute(abs_src)
		else:
			# Fallback copy bytes
			var bytes: PackedByteArray = FileAccess.get_file_as_bytes(src_path)
			var f: FileAccess = FileAccess.open(dest_path, FileAccess.WRITE)
			if f != null:
				f.store_buffer(bytes)
				f.close()
				DirAccess.remove_absolute(abs_src)
	if not FileAccess.file_exists(abs_dest):
		return {
			"ok": false,
			"blocked": false,
			"skipped": false,
			"wrote": false,
			"error": "editor_screenshot could not write distinct file",
			"log": "editor_screenshot failed: no dest",
			"result": {"ok": false, "error": "could not write distinct file"},
		}
	if dest_path == PLAY_FRAME_PATH or abs_dest == ProjectSettings.globalize_path(PLAY_FRAME_PATH):
		return {
			"ok": false,
			"blocked": false,
			"skipped": false,
			"wrote": false,
			"error": "editor_screenshot must not overwrite play frame",
			"log": "editor_screenshot failed: play frame collision",
			"result": {"ok": false, "error": "play frame collision"},
		}
	var payload: Dictionary = {
		"ok": true,
		"path": dest_path,
		"target": target,
		"play_frame": PLAY_FRAME_PATH,
	}
	return {
		"ok": true,
		"blocked": false,
		"skipped": false,
		"wrote": false,
		"error": "",
		"log": "editor_screenshot ok target=%s path=%s" % [target, dest_path],
		"result": payload,
		"shot_path": dest_path,
		"shot_target": target,
	}


# --- Write allow ops ----------------------------------------------------------

func node_duplicate(args: Dictionary) -> Dictionary:
	var path: String = str(args.get("path", "")).strip_edges()
	var page_id: String = str(args.get("page_id", "")).strip_edges()
	var node: Node = _resolve_node(path)
	if node == null:
		return _fail("node_duplicate", "node not found: %s" % path)
	var root: Node = _edited_root()
	if root == null:
		return _fail("node_duplicate", "no open scene")
	if node == root:
		return _fail("node_duplicate", "cannot duplicate scene root")
	var parent: Node = node.get_parent()
	if parent == null or not _is_under_root(parent, root):
		return _fail("node_duplicate", "parent must stay under edited scene root")
	var dup: Node = node.duplicate()
	if dup == null:
		return _fail("node_duplicate", "duplicate failed")
	var base_name: String = str(node.name) + "_copy"
	var unique: String = base_name
	var n: int = 2
	while parent.has_node(NodePath(unique)):
		unique = "%s_%d" % [base_name, n]
		n += 1
	dup.name = StringName(unique)
	_ensure_action()
	var ur: EditorUndoRedoManager = EditorInterface.get_editor_undo_redo()
	parent.add_child(dup, true)
	dup.owner = root
	_set_owner_recursive(dup, root)
	dup.set_meta(META_PAGE, page_id)
	ur.add_do_method(parent, "add_child", dup, true)
	ur.add_do_property(dup, "owner", root)
	ur.add_do_method(dup, "set_meta", META_PAGE, page_id)
	ur.add_undo_method(parent, "remove_child", dup)
	ur.add_do_reference(dup)
	_note_page(page_id)
	_note_write(true)
	var new_path: String = str(root.get_path_to(dup))
	return _ok_write("node_duplicate", {
		"ok": true,
		"path": new_path,
		"name": str(dup.name),
		"page_id": page_id,
	}, "node_duplicate ok path=%s page_id=%s" % [new_path, page_id])


func node_rename(args: Dictionary) -> Dictionary:
	var path: String = str(args.get("path", "")).strip_edges()
	var new_name: String = str(args.get("name", args.get("new_name", ""))).strip_edges()
	var page_id: String = str(args.get("page_id", "")).strip_edges()
	if new_name.is_empty():
		return _fail("node_rename", "name is required")
	var node: Node = _resolve_node(path)
	if node == null:
		return _fail("node_rename", "node not found: %s" % path)
	var root: Node = _edited_root()
	if root == null:
		return _fail("node_rename", "no open scene")
	if node == root:
		return _fail("node_rename", "cannot rename scene root")
	if not _is_under_root(node, root):
		return _fail("node_rename", "node must stay under edited scene root")
	var parent: Node = node.get_parent()
	if parent != null and parent.has_node(NodePath(new_name)) and parent.get_node(NodePath(new_name)) != node:
		return _fail("node_rename", "sibling named %s already exists" % new_name)
	var old_name: String = str(node.name)
	_ensure_action()
	var ur: EditorUndoRedoManager = EditorInterface.get_editor_undo_redo()
	ur.add_do_property(node, "name", StringName(new_name))
	ur.add_undo_property(node, "name", StringName(old_name))
	node.name = StringName(new_name)
	node.set_meta(META_PAGE, page_id)
	ur.add_do_method(node, "set_meta", META_PAGE, page_id)
	_note_page(page_id)
	_note_write(true)
	return _ok_write("node_rename", {
		"ok": true,
		"path": str(root.get_path_to(node)),
		"old_name": old_name,
		"name": new_name,
		"page_id": page_id,
	}, "node_rename ok %s -> %s page_id=%s" % [old_name, new_name, page_id])


func node_reparent(args: Dictionary) -> Dictionary:
	var path: String = str(args.get("path", "")).strip_edges()
	var parent_path: String = str(args.get("parent", args.get("new_parent", ""))).strip_edges()
	var page_id: String = str(args.get("page_id", "")).strip_edges()
	var index: int = int(args.get("index", -1))
	var node: Node = _resolve_node(path)
	if node == null:
		return _fail("node_reparent", "node not found: %s" % path)
	var root: Node = _edited_root()
	if root == null:
		return _fail("node_reparent", "no open scene")
	if node == root:
		return _fail("node_reparent", "cannot reparent scene root")
	var new_parent: Node = root if parent_path.is_empty() or parent_path == "." else _resolve_node(parent_path)
	if new_parent == null:
		return _fail("node_reparent", "parent not found: %s" % parent_path)
	if not _is_under_root(new_parent, root):
		return _fail("node_reparent", "parent must stay under edited scene root")
	if node.is_ancestor_of(new_parent) or node == new_parent:
		return _fail("node_reparent", "cannot reparent under self/descendant")
	var old_parent: Node = node.get_parent()
	if old_parent == null:
		return _fail("node_reparent", "node has no parent")
	var old_index: int = node.get_index()
	_ensure_action()
	var ur: EditorUndoRedoManager = EditorInterface.get_editor_undo_redo()
	old_parent.remove_child(node)
	new_parent.add_child(node, true)
	if index >= 0 and index < new_parent.get_child_count():
		new_parent.move_child(node, index)
	node.owner = root
	_set_owner_recursive(node, root)
	node.set_meta(META_PAGE, page_id)
	# Undo/redo: move back / forth
	ur.add_do_method(self, "_do_reparent", node, new_parent, index, root, page_id)
	ur.add_undo_method(self, "_do_reparent", node, old_parent, old_index, root, page_id)
	_note_page(page_id)
	_note_write(true)
	return _ok_write("node_reparent", {
		"ok": true,
		"path": str(root.get_path_to(node)),
		"parent": str(root.get_path_to(new_parent)),
		"page_id": page_id,
	}, "node_reparent ok path=%s parent=%s page_id=%s" % [
		str(root.get_path_to(node)), str(root.get_path_to(new_parent)), page_id
	])


func _do_reparent(node: Node, parent: Node, index: int, root: Node, page_id: String) -> void:
	if node == null or parent == null or not is_instance_valid(node) or not is_instance_valid(parent):
		return
	var cur: Node = node.get_parent()
	if cur != null:
		cur.remove_child(node)
	parent.add_child(node, true)
	if index >= 0 and index < parent.get_child_count():
		parent.move_child(node, mini(index, parent.get_child_count() - 1))
	node.owner = root
	_set_owner_recursive(node, root)
	if not page_id.is_empty():
		node.set_meta(META_PAGE, page_id)


func node_move(args: Dictionary) -> Dictionary:
	var path: String = str(args.get("path", "")).strip_edges()
	var index: int = int(args.get("index", args.get("to_index", 0)))
	var page_id: String = str(args.get("page_id", "")).strip_edges()
	var node: Node = _resolve_node(path)
	if node == null:
		return _fail("node_move", "node not found: %s" % path)
	var root: Node = _edited_root()
	if root == null:
		return _fail("node_move", "no open scene")
	if node == root:
		return _fail("node_move", "cannot move scene root")
	var parent: Node = node.get_parent()
	if parent == null or not _is_under_root(parent, root):
		return _fail("node_move", "parent must stay under edited scene root")
	var old_index: int = node.get_index()
	index = clampi(index, 0, maxi(0, parent.get_child_count() - 1))
	_ensure_action()
	var ur: EditorUndoRedoManager = EditorInterface.get_editor_undo_redo()
	parent.move_child(node, index)
	node.set_meta(META_PAGE, page_id)
	ur.add_do_method(parent, "move_child", node, index)
	ur.add_undo_method(parent, "move_child", node, old_index)
	ur.add_do_method(node, "set_meta", META_PAGE, page_id)
	_note_page(page_id)
	_note_write(true)
	return _ok_write("node_move", {
		"ok": true,
		"path": str(root.get_path_to(node)),
		"index": index,
		"old_index": old_index,
		"page_id": page_id,
	}, "node_move ok path=%s index=%d page_id=%s" % [str(root.get_path_to(node)), index, page_id])


func signal_connect(args: Dictionary) -> Dictionary:
	var from_path: String = str(args.get("from", args.get("path", ""))).strip_edges()
	var signal_name: String = str(args.get("signal", "")).strip_edges()
	var to_path: String = str(args.get("to", args.get("target", ""))).strip_edges()
	var method_name: String = str(args.get("method", "")).strip_edges()
	var page_id: String = str(args.get("page_id", "")).strip_edges()
	if from_path.is_empty() or signal_name.is_empty() or to_path.is_empty() or method_name.is_empty():
		return _fail("signal_connect", "from, signal, to, and method are required")
	var from_node: Node = _resolve_node(from_path)
	var to_node: Node = _resolve_node(to_path)
	if from_node == null:
		return _fail("signal_connect", "from node not found: %s" % from_path)
	if to_node == null:
		return _fail("signal_connect", "to node not found: %s" % to_path)
	var root: Node = _edited_root()
	if root == null:
		return _fail("signal_connect", "no open scene")
	if not _is_under_root(from_node, root) or not _is_under_root(to_node, root):
		return _fail("signal_connect", "nodes must stay under edited scene root")
	if not from_node.has_signal(signal_name):
		return _fail("signal_connect", "signal not found: %s" % signal_name)
	# Fail if method does not exist. No silent script write.
	if not to_node.has_method(method_name):
		return _fail("signal_connect", "method does not exist: %s" % method_name)
	var cb := Callable(to_node, StringName(method_name))
	if from_node.is_connected(StringName(signal_name), cb):
		return _ok_write("signal_connect", {
			"ok": true,
			"already": true,
			"from": from_path,
			"signal": signal_name,
			"to": to_path,
			"method": method_name,
			"page_id": page_id,
		}, "signal_connect already connected")
	_ensure_action()
	var ur: EditorUndoRedoManager = EditorInterface.get_editor_undo_redo()
	from_node.connect(StringName(signal_name), cb)
	from_node.set_meta(META_PAGE, page_id)
	ur.add_do_method(from_node, "connect", StringName(signal_name), cb)
	ur.add_undo_method(from_node, "disconnect", StringName(signal_name), cb)
	ur.add_do_method(from_node, "set_meta", META_PAGE, page_id)
	_note_page(page_id)
	_note_write(true)
	return _ok_write("signal_connect", {
		"ok": true,
		"from": from_path,
		"signal": signal_name,
		"to": to_path,
		"method": method_name,
		"page_id": page_id,
	}, "signal_connect ok %s.%s -> %s.%s page_id=%s" % [
		from_path, signal_name, to_path, method_name, page_id
	])


func resource_assign(args: Dictionary) -> Dictionary:
	var path: String = str(args.get("path", "")).strip_edges()
	var property: String = str(args.get("property", "")).strip_edges()
	var res_path: String = str(args.get("resource", args.get("res", ""))).strip_edges()
	var page_id: String = str(args.get("page_id", "")).strip_edges()
	if path.is_empty() or property.is_empty() or res_path.is_empty():
		return _fail("resource_assign", "path, property, and resource are required")
	if not res_path.begins_with("res://"):
		return _fail("resource_assign", "resource must be a res:// path")
	var node: Node = _resolve_node(path)
	if node == null:
		return _fail("resource_assign", "node not found: %s" % path)
	var root: Node = _edited_root()
	if root == null:
		return _fail("resource_assign", "no open scene")
	if not _is_under_root(node, root):
		return _fail("resource_assign", "node must stay under edited scene root")
	if not ResourceLoader.exists(res_path):
		return _fail("resource_assign", "resource not found: %s" % res_path)
	var res: Resource = ResourceLoader.load(res_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if res == null:
		return _fail("resource_assign", "could not load resource: %s" % res_path)
	var old_val: Variant = node.get(property)
	_ensure_action()
	var ur: EditorUndoRedoManager = EditorInterface.get_editor_undo_redo()
	node.set(property, res)
	node.set_meta(META_PAGE, page_id)
	ur.add_do_property(node, property, res)
	ur.add_undo_property(node, property, old_val)
	ur.add_do_method(node, "set_meta", META_PAGE, page_id)
	_note_page(page_id)
	_note_write(true)
	return _ok_write("resource_assign", {
		"ok": true,
		"path": path,
		"property": property,
		"resource": res_path,
		"page_id": page_id,
	}, "resource_assign ok path=%s property=%s res=%s page_id=%s" % [
		path, property, res_path, page_id
	])


# --- Confirm writes -----------------------------------------------------------

func script_patch(args: Dictionary) -> Dictionary:
	## Patch a .gd file. Parse-gate before any hot-reload. Failed parse does not overwrite a good script.
	var path: String = str(args.get("path", "")).strip_edges()
	var content: String = str(args.get("content", ""))
	var find_text: String = str(args.get("find", args.get("search", "")))
	var replace_text: String = str(args.get("replace", ""))
	var page_id: String = str(args.get("page_id", "")).strip_edges()
	if path.is_empty():
		return _fail("script_patch", "path is required")
	if not path.begins_with("res://") or not path.to_lower().ends_with(".gd"):
		return _fail("script_patch", "path must be a res:// .gd script")
	if not FileAccess.file_exists(path):
		return _fail("script_patch", "script not found: %s" % path)
	var old_src: String = FileAccess.get_file_as_string(path)
	var new_src: String = content
	if content.is_empty():
		if find_text.is_empty():
			return _fail("script_patch", "content or find/replace required")
		if old_src.find(find_text) < 0:
			return _fail("script_patch", "find text not present in script")
		new_src = old_src.replace(find_text, replace_text)
	# Parse-gate on a probe — never reload the live resource until parse succeeds.
	var probe := GDScript.new()
	probe.source_code = new_src
	var reload_err: Error = probe.reload()
	if reload_err != OK:
		return {
			"ok": false,
			"blocked": false,
			"skipped": false,
			"wrote": false,
			"error": "parse failed",
			"log": "script_patch parse failed path=%s err=%d" % [path, int(reload_err)],
			"result": {
				"ok": false,
				"phase": "parse",
				"error": "parse failed",
				"path": path,
				"reload_err": int(reload_err),
			},
		}
	# Write via undo path without hot-reloading a still-good script until parse succeeded.
	_ensure_action()
	var ur: EditorUndoRedoManager = EditorInterface.get_editor_undo_redo()
	ur.add_do_method(self, "_write_script_text", path, new_src)
	ur.add_undo_method(self, "_write_script_text", path, old_src)
	_write_script_text(path, new_src)
	# Only after successful write, refresh the ResourceLoader cache for this path.
	var loaded: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if loaded is GDScript:
		var gd: GDScript = loaded as GDScript
		gd.source_code = new_src
		var live_err: Error = gd.reload()
		if live_err != OK:
			# Restore good script on disk — do not leave a broken hot-reload.
			_write_script_text(path, old_src)
			return {
				"ok": false,
				"blocked": false,
				"skipped": false,
				"wrote": false,
				"error": "parse failed on live reload",
				"log": "script_patch live reload failed; restored prior script",
				"result": {
					"ok": false,
					"phase": "parse",
					"error": "parse failed on live reload",
					"path": path,
				},
			}
	_note_page(page_id)
	_note_write(true)
	return _ok_write("script_patch", {
		"ok": true,
		"path": path,
		"page_id": page_id,
		"phase": "ok",
	}, "script_patch ok path=%s page_id=%s" % [path, page_id])


func _write_script_text(path: String, text: String) -> void:
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(text)
	f.close()


func script_attach(args: Dictionary) -> Dictionary:
	## Attach an existing res:// .gd to a node. Parse-gate first. Always confirm (policy).
	var path: String = str(args.get("path", "")).strip_edges()
	var script_path: String = str(args.get("script", args.get("resource", ""))).strip_edges()
	var page_id: String = str(args.get("page_id", "")).strip_edges()
	if path.is_empty() or script_path.is_empty():
		return _fail("script_attach", "path and script are required")
	if not script_path.begins_with("res://") or not script_path.to_lower().ends_with(".gd"):
		return _fail("script_attach", "script must be a res:// .gd path")
	var node: Node = _resolve_node(path)
	if node == null:
		return _fail("script_attach", "node not found: %s" % path)
	var root: Node = _edited_root()
	if root == null:
		return _fail("script_attach", "no open scene")
	if not _is_under_root(node, root):
		return _fail("script_attach", "node must stay under edited scene root")
	if not FileAccess.file_exists(script_path):
		return _fail("script_attach", "script not found: %s" % script_path)
	var src: String = FileAccess.get_file_as_string(script_path)
	var probe := GDScript.new()
	probe.source_code = src
	var reload_err: Error = probe.reload()
	if reload_err != OK:
		return {
			"ok": false,
			"blocked": false,
			"skipped": false,
			"wrote": false,
			"error": "parse failed",
			"log": "script_attach parse failed path=%s err=%d" % [script_path, int(reload_err)],
			"result": {
				"ok": false,
				"phase": "parse",
				"error": "parse failed",
				"path": script_path,
				"reload_err": int(reload_err),
			},
		}
	var script_res: Script = ResourceLoader.load(script_path, "", ResourceLoader.CACHE_MODE_IGNORE) as Script
	if script_res == null:
		return _fail("script_attach", "could not load script: %s" % script_path)
	var old_script: Variant = node.get_script()
	_ensure_action()
	var ur: EditorUndoRedoManager = EditorInterface.get_editor_undo_redo()
	node.set_script(script_res)
	node.set_meta(META_PAGE, page_id)
	ur.add_do_method(node, "set_script", script_res)
	ur.add_undo_method(node, "set_script", old_script)
	ur.add_do_method(node, "set_meta", META_PAGE, page_id)
	_note_page(page_id)
	_note_write(true)
	return _ok_write("script_attach", {
		"ok": true,
		"path": path,
		"script": script_path,
		"page_id": page_id,
		"phase": "ok",
	}, "script_attach ok path=%s script=%s page_id=%s" % [path, script_path, page_id])


func input_map_ensure(args: Dictionary) -> Dictionary:
	## Add an action or binding. Writes project.godot — always confirm (policy). Never auto-approve.
	var action: String = str(args.get("action", args.get("name", ""))).strip_edges()
	if action.is_empty():
		return _fail("input_map_ensure", "action is required")
	var key_setting: String = "input/" + action
	var deadzone: float = float(args.get("deadzone", 0.5))
	var event_desc: Dictionary = {}
	if typeof(args.get("event", {})) == TYPE_DICTIONARY:
		event_desc = args.get("event", {})
	elif args.has("keycode") or args.has("key"):
		event_desc = {"type": "key", "keycode": args.get("keycode", args.get("key", ""))}
	var existing: Variant = null
	var had: bool = ProjectSettings.has_setting(key_setting)
	if had:
		existing = ProjectSettings.get_setting(key_setting)
	var events: Array = []
	if typeof(existing) == TYPE_DICTIONARY:
		var prev_events: Variant = (existing as Dictionary).get("events", [])
		if typeof(prev_events) == TYPE_ARRAY:
			events = (prev_events as Array).duplicate()
		deadzone = float((existing as Dictionary).get("deadzone", deadzone))
	var new_event: InputEvent = _build_input_event(event_desc)
	if new_event != null:
		var already := false
		for ev: Variant in events:
			if ev is InputEvent and (ev as InputEvent).is_match(new_event):
				already = true
				break
		if not already:
			events.append(new_event)
	elif not event_desc.is_empty():
		return _fail("input_map_ensure", "could not build input event from args")
	var new_val: Dictionary = {"deadzone": deadzone, "events": events}
	_ensure_action()
	var ur: EditorUndoRedoManager = EditorInterface.get_editor_undo_redo()
	ur.add_do_method(self, "_apply_input_setting", key_setting, new_val, true)
	if had:
		ur.add_undo_method(self, "_apply_input_setting", key_setting, existing, true)
	else:
		ur.add_undo_method(self, "_clear_input_setting", key_setting)
	_apply_input_setting(key_setting, new_val, true)
	_note_write(false)  # project.godot write, not a scene write
	return _ok_write("input_map_ensure", {
		"ok": true,
		"action": action,
		"setting": key_setting,
		"events": events.size(),
	}, "input_map_ensure ok action=%s events=%d" % [action, events.size()])


func _apply_input_setting(key: String, value: Variant, save: bool) -> void:
	ProjectSettings.set_setting(key, value)
	if save:
		ProjectSettings.save()


func _clear_input_setting(key: String) -> void:
	if ProjectSettings.has_setting(key):
		ProjectSettings.set_setting(key, null)
		# Clear permanently
		ProjectSettings.clear(key)
	ProjectSettings.save()


# --- Tool schemas -------------------------------------------------------------

func _read_tool_definitions() -> Array:
	return [
		_fn("scene_hierarchy",
			"Paginated walk of the edited scene. Returns node path, type, name. Read-only.",
			{
				"type": "object",
				"properties": {
					"depth": {"type": "integer", "description": "Max depth from root (default 8)"},
					"offset": {"type": "integer", "description": "Pagination offset"},
					"limit": {"type": "integer", "description": "Max nodes to return (default 100)"},
				},
				"additionalProperties": false,
			}),
		_fn("node_properties",
			"Full property snapshot of one node by path relative to the scene root. Read-only.",
			{
				"type": "object",
				"properties": {
					"path": {"type": "string", "description": "Node path from scene root"},
				},
				"required": ["path"],
				"additionalProperties": false,
			}),
		_fn("signal_list",
			"Signals on one node, including existing connections. Read-only.",
			{
				"type": "object",
				"properties": {
					"path": {"type": "string", "description": "Node path from scene root"},
				},
				"required": ["path"],
				"additionalProperties": false,
			}),
		_fn("resource_find",
			"Search project resources by type and name; return res:// paths. No assign. Read-only.",
			{
				"type": "object",
				"properties": {
					"type": {"type": "string", "description": "Godot resource class, e.g. Texture2D"},
					"name": {"type": "string", "description": "Substring match on file name"},
					"limit": {"type": "integer"},
				},
				"additionalProperties": false,
			}),
		_fn("input_map_list",
			"List Input Map action names and event summaries from project settings. No write.",
			{
				"type": "object",
				"properties": {},
				"additionalProperties": false,
			}),
		_fn("log_read",
			"Tail plugin, game (last_play.json), or editor log. Cap applied. Does not scrape Output panel.",
			{
				"type": "object",
				"properties": {
					"source": {
						"type": "string",
						"description": "plugin | game | editor",
						"enum": ["plugin", "game", "editor"],
					},
					"session_id": {"type": "string", "description": "For plugin logs (default studio)"},
					"limit": {"type": "integer", "description": "Max lines (cap 200)"},
				},
				"additionalProperties": false,
			}),
		_fn("editor_screenshot",
			"Capture the editor 3D viewport, or 2D if that is the open screen. "
			+ "Writes under user://agentic_studio/logs/editor_shots/ — distinct from "
			+ "user://agentic/last_frame.png. Not a scene write. Planner may attach only if accepts_images.",
			{
				"type": "object",
				"properties": {},
				"additionalProperties": false,
			}),
	]


func _write_allow_tool_definitions() -> Array:
	var page := {
		"type": "string",
		"description": "Owning page id/slug/title (e.g. goblin_shaman)",
	}
	return [
		_fn("node_duplicate",
			"Duplicate a node under the same parent. Requires page_id. Parent stays under scene root.",
			{
				"type": "object",
				"properties": {
					"path": {"type": "string"},
					"page_id": page,
				},
				"required": ["path", "page_id"],
				"additionalProperties": false,
			}),
		_fn("node_rename",
			"Rename a node. Requires page_id. Cannot rename the scene root.",
			{
				"type": "object",
				"properties": {
					"path": {"type": "string"},
					"name": {"type": "string"},
					"page_id": page,
				},
				"required": ["path", "name", "page_id"],
				"additionalProperties": false,
			}),
		_fn("node_reparent",
			"Reparent a node under another node in the edited scene. Requires page_id. Parent must stay under root.",
			{
				"type": "object",
				"properties": {
					"path": {"type": "string"},
					"parent": {"type": "string", "description": "New parent path from root (empty = root)"},
					"index": {"type": "integer"},
					"page_id": page,
				},
				"required": ["path", "parent", "page_id"],
				"additionalProperties": false,
			}),
		_fn("node_move",
			"Move a node to a new sibling index under its parent. Requires page_id.",
			{
				"type": "object",
				"properties": {
					"path": {"type": "string"},
					"index": {"type": "integer"},
					"page_id": page,
				},
				"required": ["path", "index", "page_id"],
				"additionalProperties": false,
			}),
		_fn("signal_connect",
			"Connect from_node.signal to to_node.method. Fails if the method does not exist. No silent script write. Requires page_id.",
			{
				"type": "object",
				"properties": {
					"from": {"type": "string"},
					"signal": {"type": "string"},
					"to": {"type": "string"},
					"method": {"type": "string"},
					"page_id": page,
				},
				"required": ["from", "signal", "to", "method", "page_id"],
				"additionalProperties": false,
			}),
		_fn("resource_assign",
			"Set a resource property on an existing node from a res:// path. Requires page_id.",
			{
				"type": "object",
				"properties": {
					"path": {"type": "string"},
					"property": {"type": "string"},
					"resource": {"type": "string", "description": "res:// path"},
					"page_id": page,
				},
				"required": ["path", "property", "resource", "page_id"],
				"additionalProperties": false,
			}),
	]


func _write_confirm_tool_definitions() -> Array:
	var page := {
		"type": "string",
		"description": "Owning page id/slug/title (e.g. goblin_shaman)",
	}
	return [
		_fn("script_patch",
			"Patch a res:// .gd script (full content or find/replace). Always confirms. "
			+ "Parse-gates before play; a failed parse does not overwrite a good script. Requires page_id.",
			{
				"type": "object",
				"properties": {
					"path": {"type": "string"},
					"content": {"type": "string", "description": "Full new source (preferred)"},
					"find": {"type": "string"},
					"replace": {"type": "string"},
					"page_id": page,
				},
				"required": ["path", "page_id"],
				"additionalProperties": false,
			}),
		_fn("script_attach",
			"Attach an existing res:// .gd script to a node. Always confirms. Parse-gates first. Requires page_id.",
			{
				"type": "object",
				"properties": {
					"path": {"type": "string", "description": "Node path"},
					"script": {"type": "string", "description": "res:// .gd path"},
					"page_id": page,
				},
				"required": ["path", "script", "page_id"],
				"additionalProperties": false,
			}),
		_fn("input_map_ensure",
			"Add an Input Map action or key binding. Writes project.godot — always confirms, never auto-approves.",
			{
				"type": "object",
				"properties": {
					"action": {"type": "string"},
					"keycode": {"type": "string", "description": "Key name e.g. KEY_SPACE or Space"},
					"event": {"type": "object"},
					"deadzone": {"type": "number"},
				},
				"required": ["action"],
				"additionalProperties": false,
			}),
	]


func _fn(name: String, description: String, parameters: Dictionary) -> Dictionary:
	return {
		"type": "function",
		"function": {
			"name": name,
			"description": description,
			"parameters": parameters,
		},
	}


# --- Helpers ------------------------------------------------------------------

func _edited_root() -> Node:
	return EditorInterface.get_edited_scene_root()


func _resolve_node(path: String) -> Node:
	var root: Node = _edited_root()
	if root == null:
		return null
	path = path.strip_edges()
	if path.is_empty() or path == "." or path == str(root.name):
		return root
	if root.has_node(NodePath(path)):
		return root.get_node(NodePath(path))
	return null


func _path_from_root(node: Node) -> String:
	var root: Node = _edited_root()
	if root == null or node == null:
		return ""
	if node == root:
		return "."
	return str(root.get_path_to(node))


func _is_under_root(node: Node, root: Node) -> bool:
	if node == null or root == null:
		return false
	if node == root:
		return true
	return root.is_ancestor_of(node)


func _set_owner_recursive(node: Node, owner: Node) -> void:
	node.owner = owner
	for i: int in range(node.get_child_count()):
		_set_owner_recursive(node.get_child(i), owner)


func _walk_hierarchy(root: Node, node: Node, depth: int, max_depth: int, out: Array) -> void:
	if depth > max_depth:
		return
	var rel: String = "." if node == root else str(root.get_path_to(node))
	out.append({
		"path": rel,
		"type": node.get_class(),
		"name": str(node.name),
		"depth": depth,
	})
	if depth == max_depth:
		return
	for i: int in range(node.get_child_count()):
		_walk_hierarchy(root, node.get_child(i), depth + 1, max_depth, out)


func _serialize_value(value: Variant) -> Variant:
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return value
		TYPE_STRING_NAME:
			return str(value)
		TYPE_VECTOR2:
			var v2: Vector2 = value
			return {"x": v2.x, "y": v2.y}
		TYPE_VECTOR3:
			var v3: Vector3 = value
			return {"x": v3.x, "y": v3.y, "z": v3.z}
		TYPE_VECTOR4:
			var v4: Vector4 = value
			return {"x": v4.x, "y": v4.y, "z": v4.z, "w": v4.w}
		TYPE_COLOR:
			var c: Color = value
			return {"r": c.r, "g": c.g, "b": c.b, "a": c.a}
		TYPE_NODE_PATH:
			return str(value)
		TYPE_OBJECT:
			if value == null:
				return null
			var obj: Object = value
			if obj is Resource:
				var rp: String = (obj as Resource).resource_path
				if not rp.is_empty():
					return {"resource": rp, "class": obj.get_class()}
				return {"class": obj.get_class()}
			if obj is Node:
				return {"node": _path_from_root(obj as Node), "class": obj.get_class()}
			return {"class": obj.get_class()}
		TYPE_ARRAY:
			var arr: Array = []
			for item: Variant in value:
				arr.append(_serialize_value(item))
			return arr
		TYPE_DICTIONARY:
			var d: Dictionary = {}
			for k: Variant in (value as Dictionary).keys():
				d[str(k)] = _serialize_value((value as Dictionary)[k])
			return d
		_:
			return str(value)


func _scan_resources(
	dir_path: String,
	type_name: String,
	name_query: String,
	out: Array,
	limit: int
) -> void:
	if out.size() >= limit:
		return
	var da: DirAccess = DirAccess.open(dir_path)
	if da == null:
		return
	da.list_dir_begin()
	var name: String = da.get_next()
	while name != "" and out.size() < limit:
		if name.begins_with(".") or name.begins_with("._"):
			name = da.get_next()
			continue
		var child: String = dir_path.rstrip("/") + "/" + name
		if dir_path == "res://":
			child = "res://" + name
		if da.current_is_dir():
			if name in [".godot", "addons", ".git"]:
				# Still scan addons? Skip .godot and .git; allow addons lightly — skip heavy.
				if name == ".godot" or name == ".git":
					name = da.get_next()
					continue
			_scan_resources(child, type_name, name_query, out, limit)
		else:
			if name.ends_with(".import") or name.ends_with(".uid"):
				name = da.get_next()
				continue
			var base: String = name.get_basename().to_lower()
			if not name_query.is_empty() and base.find(name_query) < 0 and name.to_lower().find(name_query) < 0:
				name = da.get_next()
				continue
			if not type_name.is_empty():
				var rtype: String = _guess_resource_type(child)
				if rtype.is_empty():
					name = da.get_next()
					continue
				if rtype != type_name and not ClassDB.is_parent_class(rtype, StringName(type_name)):
					name = da.get_next()
					continue
			out.append(child)
		name = da.get_next()
	da.list_dir_end()


func _guess_resource_type(path: String) -> String:
	## Avoid ResourceLoader.get_resource_type (not available as static in all 4.7 builds).
	var ext: String = path.get_extension().to_lower()
	match ext:
		"gd":
			return "GDScript"
		"tscn", "scn":
			return "PackedScene"
		"tres", "res":
			if ResourceLoader.exists(path):
				var loaded: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REUSE)
				if loaded != null:
					return loaded.get_class()
			return "Resource"
		"png", "jpg", "jpeg", "webp", "svg":
			return "Texture2D"
		"ogg", "wav", "mp3":
			return "AudioStream"
		"gdshader", "shader":
			return "Shader"
		"glb", "gltf":
			return "PackedScene"
		_:
			return ""


func _summarize_input_event(ev: Variant) -> String:
	if ev is InputEventKey:
		var k: InputEventKey = ev
		return "key:%s" % str(k.keycode if k.keycode != KEY_NONE else k.physical_keycode)
	if ev is InputEventMouseButton:
		return "mouse:%d" % (ev as InputEventMouseButton).button_index
	if ev is InputEventJoypadButton:
		return "joy_button:%d" % (ev as InputEventJoypadButton).button_index
	if ev is InputEventJoypadMotion:
		return "joy_axis:%d" % (ev as InputEventJoypadMotion).axis
	if ev is InputEvent:
		return (ev as InputEvent).as_text()
	return str(ev)


func _build_input_event(desc: Dictionary) -> InputEvent:
	if desc.is_empty():
		return null
	var typ: String = str(desc.get("type", "key")).to_lower()
	if typ == "key" or desc.has("keycode") or desc.has("key"):
		var ev := InputEventKey.new()
		var key_raw: String = str(desc.get("keycode", desc.get("key", ""))).strip_edges()
		var code: int = _parse_keycode(key_raw)
		if code == KEY_NONE and key_raw.is_empty():
			return null
		ev.keycode = code as Key
		ev.physical_keycode = code as Key
		return ev
	return null


func _parse_keycode(raw: String) -> int:
	var s: String = raw.strip_edges()
	if s.is_empty():
		return KEY_NONE
	if s.is_valid_int():
		return int(s)
	var upper: String = s.to_upper()
	if not upper.begins_with("KEY_"):
		upper = "KEY_" + upper
	# Common keys via string match on Key enum via reflection-ish table.
	var table: Dictionary = {
		"KEY_A": KEY_A, "KEY_B": KEY_B, "KEY_C": KEY_C, "KEY_D": KEY_D,
		"KEY_E": KEY_E, "KEY_F": KEY_F, "KEY_G": KEY_G, "KEY_H": KEY_H,
		"KEY_I": KEY_I, "KEY_J": KEY_J, "KEY_K": KEY_K, "KEY_L": KEY_L,
		"KEY_M": KEY_M, "KEY_N": KEY_N, "KEY_O": KEY_O, "KEY_P": KEY_P,
		"KEY_Q": KEY_Q, "KEY_R": KEY_R, "KEY_S": KEY_S, "KEY_T": KEY_T,
		"KEY_U": KEY_U, "KEY_V": KEY_V, "KEY_W": KEY_W, "KEY_X": KEY_X,
		"KEY_Y": KEY_Y, "KEY_Z": KEY_Z,
		"KEY_SPACE": KEY_SPACE, "KEY_ENTER": KEY_ENTER, "KEY_ESCAPE": KEY_ESCAPE,
		"KEY_TAB": KEY_TAB, "KEY_SHIFT": KEY_SHIFT, "KEY_CTRL": KEY_CTRL,
		"KEY_ALT": KEY_ALT, "KEY_UP": KEY_UP, "KEY_DOWN": KEY_DOWN,
		"KEY_LEFT": KEY_LEFT, "KEY_RIGHT": KEY_RIGHT,
	}
	if table.has(upper):
		return int(table[upper])
	# Single letter
	if s.length() == 1:
		var ch: String = s.to_upper()
		var letter_key: String = "KEY_" + ch
		if table.has(letter_key):
			return int(table[letter_key])
	return KEY_NONE


func _tail_file(res_path: String, max_lines: int) -> PackedStringArray:
	var abs_path: String = ProjectSettings.globalize_path(res_path)
	return _tail_abs_file(abs_path, max_lines)


func _tail_abs_file(abs_path: String, max_lines: int) -> PackedStringArray:
	if not FileAccess.file_exists(abs_path) and not FileAccess.file_exists(abs_path):
		# Also try as res/user path already globalized
		pass
	if not FileAccess.file_exists(abs_path):
		# Try opening via res path form
		return PackedStringArray()
	var text: String = FileAccess.get_file_as_string(abs_path)
	if text.is_empty():
		return PackedStringArray()
	var lines: PackedStringArray = PackedStringArray(text.split("\n"))
	if lines.size() <= max_lines:
		return lines
	return lines.slice(lines.size() - max_lines, lines.size())


func _editor_log_path() -> String:
	## Godot editor log on macOS/Linux under user data. Do not scrape Output panel.
	var base: String = OS.get_user_data_dir().get_base_dir()
	# Typical: .../Godot/app_userdata/<project> → sibling logs under Godot/
	var candidates: PackedStringArray = PackedStringArray([
		OS.get_user_data_dir().path_join("logs").path_join("godot.log"),
		base.path_join("logs").path_join("godot.log"),
		ProjectSettings.globalize_path("user://logs/godot.log"),
	])
	# Also check EditorPaths if available
	if ClassDB.class_exists("EditorPaths"):
		pass
	for c: String in candidates:
		if FileAccess.file_exists(c):
			return c
	# macOS Godot logs
	var home: String = OS.get_environment("HOME")
	if not home.is_empty():
		var mac: String = home.path_join("Library/Application Support/Godot/logs/godot.log")
		if FileAccess.file_exists(mac):
			return mac
	return candidates[0] if candidates.size() > 0 else ""


func _ensure_action() -> void:
	if _tools != null and _tools.has_method("_ensure_action"):
		_tools.call("_ensure_action")


func _note_write(scene_or_script: bool) -> void:
	if _tools != null and _tools.has_method("_note_write"):
		_tools.call("_note_write", scene_or_script)


func _note_page(page_id: String) -> void:
	if _tools != null and _tools.has_method("_note_page"):
		_tools.call("_note_page", page_id)


func _fail(tool_name: String, message: String) -> Dictionary:
	return {
		"ok": false,
		"blocked": false,
		"skipped": false,
		"wrote": false,
		"error": message,
		"log": "%s failed: %s" % [tool_name, message],
		"result": {"ok": false, "error": message},
	}


func _ok(tool_name: String, payload: Dictionary, log_line: String) -> Dictionary:
	return {
		"ok": true,
		"blocked": false,
		"skipped": false,
		"wrote": false,
		"error": "",
		"log": log_line,
		"result": payload,
	}


func _ok_write(tool_name: String, payload: Dictionary, log_line: String) -> Dictionary:
	return {
		"ok": true,
		"blocked": false,
		"skipped": false,
		"wrote": true,
		"error": "",
		"log": log_line,
		"result": payload,
	}
