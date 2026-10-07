class_name AgenticStudioSceneTools
extends RefCounted
## In-process scene and page tools. One undo action per job.

const PlaySupportScript = preload("res://addons/agentic_studio/play_support.gd")
const PageStoreScript = preload("res://addons/agentic_studio/page_store.gd")
const AssetSupportScript = preload("res://addons/agentic_studio/asset_support.gd")
const FileSupportScript = preload("res://addons/agentic_studio/file_support.gd")
const ScreenshotSupportScript = preload("res://addons/agentic_studio/screenshot_support.gd")
const EditorOpsScript = preload("res://addons/agentic_studio/editor_ops.gd")
const PolicyScript = preload("res://addons/agentic_studio/policy.gd")

const TOOL_READ_SCENE: String = "read_scene"
const TOOL_ADD_NODE: String = "add_node"
const TOOL_SET_PROPERTY: String = "set_property"
const TOOL_PLAY_SCENE: String = "play_scene"
const TOOL_LIST_PAGES: String = "list_pages"
const TOOL_GET_PAGE: String = "get_page"
const TOOL_LINK: String = "link"
const TOOL_CREATE_ASSET: String = "create_asset"
const TOOL_LIST_DIR: String = "list_dir"
const TOOL_READ_FILE: String = "read_file"
const TOOL_WRITE_FILE: String = "write_file"
const TOOL_DELETE_FILE: String = "delete_file"
const TOOL_SCREENSHOT: String = "screenshot"
const TOOL_CHECK_PAGE_DRIFT: String = "check_page_drift"
const TOOL_EDITOR_SCREENSHOT: String = "editor_screenshot"

const BLOCKED_MESSAGE: String = "blocked — confirm later"
const MAX_WRITES_PER_JOB: int = 4
const REFUSED_FIFTH_WRITE: String = "refused fifth write (cap 4)"
const META_PAGE: String = "agentic_page"

var job_id: String = ""
## Session id for shot directory (studio or session_*). Set by the dock before run.
var session_id: String = "session"
var _action_open: bool = false
var _wrote: bool = false
var _scene_wrote: bool = false
var _committed: bool = false
var _write_ops: int = 0
## Paths of screenshots to attach on the next model request when accepts_images.
var pending_shot_paths: PackedStringArray = PackedStringArray()
## Cited page ids for play result + session log.
var cited_page_ids: PackedStringArray = PackedStringArray()
## Compact op summaries for session log.
var ops_log: Array = []
## Last play result dictionary (stable shape) for session log.
var last_play_result: Variant = null
## Kept alive for UndoRedo do/undo methods on page links.
var _page_store: RefCounted = PageStoreScript.new()
## Kept alive for UndoRedo do/undo methods on file writes/deletes.
var _file_store: RefCounted = FileSupportScript.new()
var _shot_support: RefCounted = ScreenshotSupportScript.new()
## Extra editor ops (hierarchy, signals, script_patch, input_map, …).
var _editor_ops: RefCounted = EditorOpsScript.new()


static func tool_definitions() -> Array:
	## Coder catalog. play_scene is the plugin gate after allow-class writes — not a model tool.
	## read_scene is superseded by scene_hierarchy for model-facing lists.
	var tools: Array = [
		{
			"type": "function",
			"function": {
				"name": TOOL_ADD_NODE,
				"description": (
					"Add a child node of the given Godot type and name under the current scene root. "
					+ "Requires page_id. Sets metadata agentic_page on the node. "
					+ "Prefer Node3D / MeshInstance3D / CollisionShape3D / Camera3D unless class_get says otherwise."
				),
				"parameters": {
					"type": "object",
					"properties": {
						"type": {
							"type": "string",
							"description": "Godot node class name, e.g. Node3D",
						},
						"name": {
							"type": "string",
							"description": "Node name to assign",
						},
						"page_id": {
							"type": "string",
							"description": "Owning page id/slug/title (e.g. goblin_shaman)",
						},
					},
					"required": ["type", "name", "page_id"],
					"additionalProperties": false,
				},
			},
		},
		{
			"type": "function",
			"function": {
				"name": TOOL_SET_PROPERTY,
				"description": (
					"Set one property on an existing node by path from the scene root. "
					+ "Requires page_id. Call node_properties first; properties absent from that "
					+ "snapshot are rejected. property=script is confirm, not allow."
				),
				"parameters": {
					"type": "object",
					"properties": {
						"path": {
							"type": "string",
							"description": "Node path from scene root, e.g. AgentProbe or Child/Grandchild",
						},
						"property": {
							"type": "string",
							"description": "Property name, e.g. position",
						},
						"value": {
							"description": "New property value (JSON scalar or object)",
						},
						"page_id": {
							"type": "string",
							"description": "Owning page id/slug/title (e.g. goblin_shaman)",
						},
					},
					"required": ["path", "property", "value", "page_id"],
					"additionalProperties": false,
				},
			},
		},
		{
			"type": "function",
			"function": {
				"name": TOOL_CREATE_ASSET,
				"description": (
					"Copy the known stand-in GLB into res://inbox/, optionally decimate if Blender "
					+ "is configured, import it, instance it under the current scene root, create "
					+ "an asset page, and link it from the named character page. This is a write. "
					+ "Requires page_id (usually the character page). No default material or cel shader."
				),
				"parameters": {
					"type": "object",
					"properties": {
						"character": {
							"type": "string",
							"description": "Character page title or path (e.g. Goblin Shaman)",
						},
						"source": {
							"type": "string",
							"description": "Optional GLB path; defaults to the project stand-in mesh",
						},
						"page_id": {
							"type": "string",
							"description": "Owning page id/slug/title (e.g. goblin_shaman)",
						},
					},
					"required": ["character", "page_id"],
					"additionalProperties": false,
				},
			},
		},
	]
	tools.append_array(page_tool_definitions())
	tools.append_array(file_tool_definitions())
	tools.append_array(screenshot_tool_definitions())
	tools.append_array(EditorOpsScript.new().tool_definitions())
	return tools


static func screenshot_tool_definitions() -> Array:
	return [
		{
			"type": "function",
			"function": {
				"name": TOOL_SCREENSHOT,
				"description": (
					"Capture a PNG of the editor or running game. "
					+ "target: editor_2d, editor_3d, or play. "
					+ "play uses the running game window and does not start a new play. "
					+ "Not a scene write. Returns the saved path under user://agentic_studio/logs/shots/."
				),
				"parameters": {
					"type": "object",
					"properties": {
						"target": {
							"type": "string",
							"description": "editor_2d | editor_3d | play",
							"enum": ["editor_2d", "editor_3d", "play"],
						},
					},
					"required": ["target"],
					"additionalProperties": false,
				},
			},
		},
	]


static func file_tool_definitions() -> Array:
	return [
		{
			"type": "function",
			"function": {
				"name": TOOL_LIST_DIR,
				"description": (
					"List files under a res:// path the cited page points at (page file, links, "
					+ "image_paths, or their directories). Call get_page first. Not a project-wide search."
				),
				"parameters": {
					"type": "object",
					"properties": {
						"path": {
							"type": "string",
							"description": "Directory under res:// (default res://)",
						},
					},
					"additionalProperties": false,
				},
			},
		},
		{
			"type": "function",
			"function": {
				"name": TOOL_READ_FILE,
				"description": (
					"Read a text file under res:// that a cited page points at. "
					+ "Call get_page first. Not a project-wide search. Refuses user://."
				),
				"parameters": {
					"type": "object",
					"properties": {
						"path": {
							"type": "string",
							"description": "res:// path to a text file",
						},
					},
					"required": ["path"],
					"additionalProperties": false,
				},
			},
		},
		{
			"type": "function",
			"function": {
				"name": TOOL_WRITE_FILE,
				"description": (
					"Create or replace a text file under res://. This is a write. "
					+ "Joins the job undo action. Script or scene writes require page_id and trigger the play gate. "
					+ "Script body always asks for confirm."
				),
				"parameters": {
					"type": "object",
					"properties": {
						"path": {
							"type": "string",
							"description": "res:// path to write",
						},
						"content": {
							"type": "string",
							"description": "Full text file contents",
						},
						"page_id": {
							"type": "string",
							"description": "Owning page id when writing a script or scene",
						},
					},
					"required": ["path", "content"],
					"additionalProperties": false,
				},
			},
		},
		{
			"type": "function",
			"function": {
				"name": TOOL_DELETE_FILE,
				"description": (
					"Delete a page (.tres), scene (.tscn), or script (.gd) under res://. "
					+ "Always asks for confirmation. Never deletes user://. Log includes the path."
				),
				"parameters": {
					"type": "object",
					"properties": {
						"path": {
							"type": "string",
							"description": "res:// path to delete",
						},
					},
					"required": ["path"],
					"additionalProperties": false,
				},
			},
		},
	]


static func page_tool_definitions() -> Array:
	return [
		{
			"type": "function",
			"function": {
				"name": TOOL_LIST_PAGES,
				"description": "List character and asset pages: title, kind, and path for each.",
				"parameters": {
					"type": "object",
					"properties": {},
					"additionalProperties": false,
				},
			},
		},
		{
			"type": "function",
			"function": {
				"name": TOOL_GET_PAGE,
				"description": (
					"Get one page by title or res:// .tres path: notes, tags, image paths, and links. "
					+ "Prefer the page title (e.g. Goblin Shaman). Call list_pages first if unsure. "
					+ "Pages are .tres under res://studio/characters/ or res://studio/assets/."
				),
				"parameters": {
					"type": "object",
					"properties": {
						"path": {
							"type": "string",
							"description": "Page title (preferred) or res://studio/.../*.tres path",
						},
					},
					"required": ["path"],
					"additionalProperties": false,
				},
			},
		},
		{
			"type": "function",
			"function": {
				"name": TOOL_LINK,
				"description": (
					"Record a link from one page to another page path. This is a write."
				),
				"parameters": {
					"type": "object",
					"properties": {
						"from": {
							"type": "string",
							"description": "Source page path or title",
						},
						"to": {
							"type": "string",
							"description": "Target page path or title",
						},
					},
					"required": ["from", "to"],
					"additionalProperties": false,
				},
			},
		},
		{
			"type": "function",
			"function": {
				"name": TOOL_CHECK_PAGE_DRIFT,
				"description": (
					"Read-only: compare nodes tagged with metadata agentic_page for the given page_id "
					+ "to a simple live snapshot and return drift findings. Does not rewrite the scene."
				),
				"parameters": {
					"type": "object",
					"properties": {
						"page_id": {
							"type": "string",
							"description": "Page id/slug/title to check",
						},
					},
					"required": ["page_id"],
					"additionalProperties": false,
				},
			},
		},
	]


static func plan_tool_definitions() -> Array:
	## Planner catalog: reads only. Write-shaped planner replies are discarded.
	var out: Array = []
	for t: Variant in page_tool_definitions():
		if typeof(t) != TYPE_DICTIONARY:
			continue
		var fn: Variant = (t as Dictionary).get("function", {})
		if typeof(fn) != TYPE_DICTIONARY:
			continue
		var name: String = str((fn as Dictionary).get("name", ""))
		if (
			name == TOOL_LIST_PAGES
			or name == TOOL_GET_PAGE
			or name == TOOL_CHECK_PAGE_DRIFT
		):
			out.append(t)
	for t2: Variant in file_tool_definitions():
		if typeof(t2) != TYPE_DICTIONARY:
			continue
		var fn2: Variant = (t2 as Dictionary).get("function", {})
		if typeof(fn2) != TYPE_DICTIONARY:
			continue
		var name2: String = str((fn2 as Dictionary).get("name", ""))
		if name2 == TOOL_LIST_DIR or name2 == TOOL_READ_FILE:
			out.append(t2)
	out.append_array(screenshot_tool_definitions())
	out.append_array(EditorOpsScript.new().plan_tool_definitions())
	return out


static func is_write_tool(tool_name: String) -> bool:
	if (
		tool_name == TOOL_ADD_NODE
		or tool_name == TOOL_SET_PROPERTY
		or tool_name == TOOL_LINK
		or tool_name == TOOL_CREATE_ASSET
		or tool_name == TOOL_WRITE_FILE
		or tool_name == TOOL_DELETE_FILE
	):
		return true
	return EditorOpsScript.is_write_tool(tool_name)


static func is_always_confirm_tool(tool_name: String, args: Dictionary = {}) -> bool:
	## Policy CONFIRM class always asks, including Auto-approve. Model id ignored.
	return PolicyScript.needs_confirm(tool_name, args)


static func is_plan_tool(tool_name: String) -> bool:
	if (
		tool_name == TOOL_LIST_PAGES
		or tool_name == TOOL_GET_PAGE
		or tool_name == TOOL_LIST_DIR
		or tool_name == TOOL_READ_FILE
		or tool_name == TOOL_SCREENSHOT
		or tool_name == TOOL_CHECK_PAGE_DRIFT
	):
		return true
	return EditorOpsScript.is_read_tool(tool_name)


static func is_allowed_tool(tool_name: String) -> bool:
	if (
		tool_name == TOOL_READ_SCENE
		or tool_name == TOOL_ADD_NODE
		or tool_name == TOOL_SET_PROPERTY
		or tool_name == TOOL_PLAY_SCENE
		or tool_name == TOOL_LIST_PAGES
		or tool_name == TOOL_GET_PAGE
		or tool_name == TOOL_LINK
		or tool_name == TOOL_CREATE_ASSET
		or tool_name == TOOL_LIST_DIR
		or tool_name == TOOL_READ_FILE
		or tool_name == TOOL_WRITE_FILE
		or tool_name == TOOL_DELETE_FILE
		or tool_name == TOOL_SCREENSHOT
		or tool_name == TOOL_CHECK_PAGE_DRIFT
	):
		return true
	return EditorOpsScript.is_read_tool(tool_name) or EditorOpsScript.is_write_tool(tool_name)


static func is_blocked_tool(tool_name: String) -> bool:
	var n: String = tool_name.strip_edges().to_lower().replace("-", "_")
	if is_allowed_tool(tool_name):
		return false
	if n == "delete" or n.begins_with("delete_") or n.begins_with("remove_"):
		return true
	if n == "project_settings" or n.begins_with("project_setting"):
		return true
	return true # unknown tools are not executed


func setup(p_job_id: String, p_session_id: String = "") -> void:
	job_id = p_job_id
	if not p_session_id.strip_edges().is_empty():
		session_id = p_session_id.strip_edges()
	_action_open = false
	_wrote = false
	_scene_wrote = false
	_committed = false
	_write_ops = 0
	pending_shot_paths = PackedStringArray()
	cited_page_ids = PackedStringArray()
	ops_log = []
	last_play_result = null
	_page_store = PageStoreScript.new()
	_file_store = FileSupportScript.new()
	_shot_support = ScreenshotSupportScript.new()
	_editor_ops = EditorOpsScript.new()
	if _editor_ops.has_method("bind_tools"):
		_editor_ops.call("bind_tools", self)


func has_writes() -> bool:
	return _wrote


func has_scene_writes() -> bool:
	## Scene edits only — page link writes do not trigger the play gate.
	return _scene_wrote


func finish() -> void:
	## Commit the single undo action if any write happened.
	if _committed:
		return
	if _action_open and _wrote:
		var ur: EditorUndoRedoManager = EditorInterface.get_editor_undo_redo()
		ur.commit_action(false)
		_committed = true
		_action_open = false
	elif _action_open:
		# Opened but nothing written — should not happen; discard by not committing.
		_action_open = false


func discard_if_empty() -> void:
	## Failed HTTP with no writes: commit nothing.
	if _wrote:
		finish()
		return
	_action_open = false
	_committed = true


func execute(tool_name: String, args: Dictionary) -> Dictionary:
	## Returns {ok, blocked, skipped, wrote, result|error, log}.
	if is_blocked_tool(tool_name) and not is_allowed_tool(tool_name):
		return {
			"ok": false,
			"blocked": true,
			"skipped": false,
			"wrote": false,
			"error": BLOCKED_MESSAGE,
			"log": BLOCKED_MESSAGE,
			"result": {"ok": false, "error": BLOCKED_MESSAGE},
		}

	if is_write_tool(tool_name):
		var capped: Dictionary = _refuse_if_write_capped(tool_name)
		if not capped.is_empty():
			return capped

	_record_op(tool_name, args)
	match tool_name:
		TOOL_READ_SCENE:
			return _read_scene()
		TOOL_ADD_NODE:
			return _add_node(
				str(args.get("type", "")),
				str(args.get("name", "")),
				str(args.get("page_id", ""))
			)
		TOOL_SET_PROPERTY:
			return _set_property(
				str(args.get("path", "")),
				str(args.get("property", "")),
				args.get("value", null),
				str(args.get("page_id", ""))
			)
		TOOL_CHECK_PAGE_DRIFT:
			return _check_page_drift(str(args.get("page_id", "")))
		TOOL_PLAY_SCENE:
			# Callers that need a real play must await execute_play(); sync path is a stub.
			return {
				"ok": false,
				"blocked": false,
				"skipped": false,
				"wrote": false,
				"error": "play_scene requires async execute_play",
				"log": "play_scene failed: use async path",
				"result": {"ok": false, "error": "play_scene requires async execute_play"},
			}
		TOOL_SCREENSHOT:
			return {
				"ok": false,
				"blocked": false,
				"skipped": false,
				"wrote": false,
				"error": "screenshot requires async execute_screenshot",
				"log": "screenshot failed: use async path",
				"result": {"ok": false, "error": "screenshot requires async execute_screenshot"},
			}
		TOOL_CREATE_ASSET:
			return {
				"ok": false,
				"blocked": false,
				"skipped": false,
				"wrote": false,
				"error": "create_asset requires async execute_create_asset",
				"log": "create_asset failed: use async path",
				"result": {"ok": false, "error": "create_asset requires async execute_create_asset"},
			}
		TOOL_LIST_PAGES:
			return _list_pages()
		TOOL_GET_PAGE:
			return _get_page(str(args.get("path", args.get("title", ""))))
		TOOL_LINK:
			return _link(str(args.get("from", "")), str(args.get("to", "")))
		TOOL_LIST_DIR:
			return _list_dir(str(args.get("path", "res://")))
		TOOL_READ_FILE:
			return _read_file(str(args.get("path", "")))
		TOOL_WRITE_FILE:
			return _write_file(
				str(args.get("path", "")),
				str(args.get("content", "")),
				str(args.get("page_id", ""))
			)
		TOOL_DELETE_FILE:
			return _delete_file(str(args.get("path", "")))
		TOOL_EDITOR_SCREENSHOT:
			return {
				"ok": false,
				"blocked": false,
				"skipped": false,
				"wrote": false,
				"error": "editor_screenshot requires async execute_editor_screenshot",
				"log": "editor_screenshot failed: use async path",
				"result": {"ok": false, "error": "editor_screenshot requires async execute_editor_screenshot"},
			}
		_:
			if EditorOpsScript.is_read_tool(tool_name) or EditorOpsScript.is_write_tool(tool_name):
				if EditorOpsScript.requires_page_id(tool_name):
					var page_res: Dictionary = _require_page_id(str(args.get("page_id", "")))
					if not bool(page_res.get("ok", false)):
						return _page_id_failure(
							tool_name, str(page_res.get("error", "page_id required"))
						)
					# Normalize page_id in args for the op implementation.
					var args2: Dictionary = args.duplicate()
					args2["page_id"] = str(page_res.get("page_id", ""))
					return _editor_ops.call("execute", tool_name, args2)
				return _editor_ops.call("execute", tool_name, args)
			return {
				"ok": false,
				"blocked": true,
				"skipped": false,
				"wrote": false,
				"error": BLOCKED_MESSAGE,
				"log": BLOCKED_MESSAGE,
				"result": {"ok": false, "error": BLOCKED_MESSAGE},
			}


func _refuse_if_write_capped(tool_name: String) -> Dictionary:
	## Empty dict means allowed. After 4 successful writes, further writes are refused.
	if _write_ops < MAX_WRITES_PER_JOB:
		return {}
	var msg: String = "%s: %s" % [REFUSED_FIFTH_WRITE, tool_name]
	return {
		"ok": false,
		"blocked": false,
		"skipped": false,
		"wrote": false,
		"refused": true,
		"error": REFUSED_FIFTH_WRITE,
		"log": msg,
		"result": {"ok": false, "error": REFUSED_FIFTH_WRITE},
	}


func _note_write(scene_or_script: bool = false) -> void:
	_wrote = true
	_write_ops += 1
	if scene_or_script:
		_scene_wrote = true


func execute_editor_screenshot(args: Dictionary = {}) -> Dictionary:
	## Async editor-only shot; distinct file from user://agentic/last_frame.png.
	_record_op(TOOL_EDITOR_SCREENSHOT, args)
	var outcome: Dictionary = await _editor_ops.call("execute_editor_screenshot", session_id)
	if bool(outcome.get("ok", false)):
		var path: String = str(outcome.get("shot_path", outcome.get("result", {}).get("path", "")))
		if not path.is_empty():
			pending_shot_paths.append(path)
	return outcome


func execute_screenshot(args: Dictionary) -> Dictionary:
	## Async screenshot: capture viewport, save PNG, prune to 5 per session. Not a write.
	var target: String = str(args.get("target", args.get("view", "editor_3d")))
	var captured: Dictionary = await _shot_support.capture(session_id, target)
	if not bool(captured.get("ok", false)):
		return {
			"ok": false,
			"blocked": false,
			"skipped": false,
			"wrote": false,
			"error": str(captured.get("error", "screenshot failed")),
			"log": str(captured.get("log", "screenshot failed")),
			"result": {
				"ok": false,
				"error": str(captured.get("error", "")),
				"target": str(captured.get("target", target)),
			},
		}
	var path: String = str(captured.get("path", ""))
	var tgt: String = str(captured.get("target", target))
	pending_shot_paths.append(path)
	var pruned: PackedStringArray = PackedStringArray(captured.get("pruned", PackedStringArray()))
	var payload: Dictionary = {
		"ok": true,
		"path": path,
		"target": tgt,
		"pruned": pruned,
	}
	return {
		"ok": true,
		"blocked": false,
		"skipped": false,
		"wrote": false,
		"error": "",
		"log": str(captured.get("log", "screenshot ok")),
		"result": payload,
		"shot_path": path,
		"shot_target": tgt,
		"pruned_shots": pruned,
	}


func execute_play() -> Dictionary:
	## Async play_scene tool. Await this from Run / Auto-approve finish and tool rounds.
	var support = PlaySupportScript.new()
	var play_result: Dictionary = await support.play_current_scene(
		PlaySupportScript.PLAY_TIMEOUT_SEC,
		cited_page_ids
	)
	last_play_result = play_result
	var log_line: String = PlaySupportScript.format_play_log(play_result)
	var ok: bool = bool(play_result.get("ok", false))
	return {
		"ok": ok,
		"blocked": false,
		"skipped": false,
		"wrote": false,
		"error": "" if ok else log_line,
		"log": log_line,
		"result": play_result,
	}


func execute_create_asset(args: Dictionary) -> Dictionary:
	## Async create_asset: copy stand-in, optional decimate, import, instance, asset page + link.
	_record_op(TOOL_CREATE_ASSET, args)
	var capped: Dictionary = _refuse_if_write_capped(TOOL_CREATE_ASSET)
	if not capped.is_empty():
		return capped
	var page_res: Dictionary = _require_page_id(str(args.get("page_id", "")))
	if not bool(page_res.get("ok", false)):
		return _page_id_failure("create_asset", str(page_res.get("error", "page_id required")))
	var page_id: String = str(page_res.get("page_id", ""))
	var character_ref: String = str(args.get("character", args.get("page", ""))).strip_edges()
	var source: String = str(args.get("source", "")).strip_edges()
	if character_ref.is_empty():
		var err_args: Dictionary = {"ok": false, "error": "character is required"}
		return {
			"ok": false,
			"blocked": false,
			"skipped": false,
			"wrote": false,
			"error": err_args["error"],
			"log": "create_asset failed: %s" % err_args["error"],
			"result": err_args,
		}

	var char_path: String = PageStoreScript.resolve_page_path(character_ref)
	var char_page: Resource = null
	if not char_path.is_empty():
		char_page = PageStoreScript.load_page(char_path)
	if char_page == null:
		char_page = PageStoreScript.find_by_title(character_ref)
	if char_page == null:
		var err_missing: Dictionary = {
			"ok": false,
			"error": "character page not found: %s" % character_ref,
		}
		return {
			"ok": false,
			"blocked": false,
			"skipped": false,
			"wrote": false,
			"error": err_missing["error"],
			"log": "create_asset failed: %s" % err_missing["error"],
			"result": err_missing,
		}
	var character_title: String = str(char_page.get("title")).strip_edges()
	if character_title.is_empty():
		character_title = character_ref
	char_path = str(char_page.resource_path)

	var copied: Dictionary = AssetSupportScript.copy_stand_in_to_inbox(character_title, source)
	if not bool(copied.get("ok", false)):
		return {
			"ok": false,
			"blocked": false,
			"skipped": false,
			"wrote": false,
			"error": str(copied.get("error", "copy failed")),
			"log": "create_asset failed: %s" % str(copied.get("error", "copy failed")),
			"result": {"ok": false, "error": str(copied.get("error", "copy failed"))},
		}
	var original_glb: String = str(copied.get("path", ""))
	var inbox_glb: String = original_glb
	var log_lines: PackedStringArray = PackedStringArray([
		"create_asset copied stand-in -> %s" % inbox_glb,
	])

	var decimated: Dictionary = AssetSupportScript.maybe_decimate(inbox_glb)
	log_lines.append(str(decimated.get("log", "")))
	inbox_glb = str(decimated.get("path", inbox_glb))

	var support = AssetSupportScript.new()
	var instance_name: String = "%s_StandIn" % PageStoreScript.slugify(character_title)
	var imported: Dictionary = await support.import_and_instance(inbox_glb, instance_name)
	# If the decimated mesh fails to import, fall back to the original stand-in copy.
	if not bool(imported.get("ok", false)) and inbox_glb != original_glb:
		log_lines.append(str(imported.get("log", "import failed")))
		log_lines.append("create_asset falling back to original stand-in")
		inbox_glb = original_glb
		imported = await support.import_and_instance(inbox_glb, instance_name)
	if bool(imported.get("ok", false)):
		var n: Node = imported.get("node")
		if n != null:
			n.name = instance_name
	if not bool(imported.get("ok", false)):
		log_lines.append(str(imported.get("log", "import failed")))
		return {
			"ok": false,
			"blocked": false,
			"skipped": false,
			"wrote": false,
			"error": str(imported.get("error", "import failed")),
			"log": "\n".join(log_lines),
			"result": {
				"ok": false,
				"error": str(imported.get("error", "import failed")),
				"inbox": inbox_glb,
			},
		}
	log_lines.append(str(imported.get("log", "import ok")))

	var root: Node = EditorInterface.get_edited_scene_root()
	var node: Node = imported.get("node")
	_ensure_action()
	var ur: EditorUndoRedoManager = EditorInterface.get_editor_undo_redo()
	root.add_child(node, true)
	if node.get_parent() == root:
		node.owner = root
	node.set_meta(META_PAGE, page_id)
	ur.add_do_method(root, "add_child", node, true)
	ur.add_do_property(node, "owner", root)
	ur.add_do_method(node, "set_meta", META_PAGE, page_id)
	ur.add_undo_method(root, "remove_child", node)
	ur.add_do_reference(node)
	_note_page(page_id)
	_note_write(true)
	log_lines.append("create_asset instanced name=%s page_id=%s" % [str(node.name), page_id])

	# Asset page is project data (may remain after undo). Link from character page.
	var page_out: Dictionary = AssetSupportScript.create_asset_page(character_title, inbox_glb)
	if not bool(page_out.get("ok", false)):
		log_lines.append("asset page failed: %s" % str(page_out.get("error", "")))
		return {
			"ok": false,
			"blocked": false,
			"skipped": false,
			"wrote": true,
			"error": str(page_out.get("error", "asset page failed")),
			"log": "\n".join(log_lines),
			"result": {
				"ok": false,
				"error": str(page_out.get("error", "asset page failed")),
				"inbox": inbox_glb,
				"instance": str(node.name),
			},
		}
	var asset_path: String = str(page_out.get("path", ""))
	log_lines.append("asset page ok path=%s" % asset_path)
	var link_out: Dictionary = _page_store.add_link(char_path, asset_path)
	if bool(link_out.get("ok", false)):
		log_lines.append("link ok from=%s to=%s" % [char_path, asset_path])
	else:
		log_lines.append("link failed: %s" % str(link_out.get("error", "")))

	if EditorInterface.get_resource_filesystem() != null:
		EditorInterface.get_resource_filesystem().scan()

	var payload: Dictionary = {
		"ok": true,
		"inbox": inbox_glb,
		"instance": str(node.name),
		"asset_page": asset_path,
		"character_page": char_path,
		"decimate_skipped": bool(decimated.get("skipped", true)),
	}
	return {
		"ok": true,
		"blocked": false,
		"skipped": false,
		"wrote": true,
		"error": "",
		"log": "\n".join(log_lines),
		"result": payload,
	}


func execute_skipped(tool_name: String, args: Dictionary) -> Dictionary:
	var log_line: String = "skipped %s %s" % [tool_name, JSON.stringify(args)]
	return {
		"ok": false,
		"blocked": false,
		"skipped": true,
		"wrote": false,
		"error": "skipped by user",
		"log": log_line,
		"result": {"ok": false, "error": "skipped by user"},
	}


func _ensure_action() -> void:
	if _action_open:
		return
	var ur: EditorUndoRedoManager = EditorInterface.get_editor_undo_redo()
	# Bind to the edited scene so file + node writes share one undo history.
	var root: Node = EditorInterface.get_edited_scene_root()
	if root != null:
		ur.create_action(job_id, UndoRedo.MERGE_DISABLE, root)
	else:
		ur.create_action(job_id)
	_action_open = true


func _read_scene() -> Dictionary:
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		var err: Dictionary = {"ok": false, "error": "no open scene"}
		return {
			"ok": false,
			"blocked": false,
			"skipped": false,
			"wrote": false,
			"error": "no open scene",
			"log": "read_scene failed: no open scene",
			"result": err,
		}
	var child_names: PackedStringArray = PackedStringArray()
	for i: int in range(root.get_child_count()):
		child_names.append(str(root.get_child(i).name))
	var payload: Dictionary = {
		"ok": true,
		"path": str(root.scene_file_path),
		"root": str(root.name),
		"children": Array(child_names),
	}
	return {
		"ok": true,
		"blocked": false,
		"skipped": false,
		"wrote": false,
		"error": "",
		"log": "read_scene ok path=%s root=%s children=%s" % [
			payload["path"], payload["root"], str(payload["children"])
		],
		"result": payload,
	}


func _add_node(type_name: String, node_name: String, page_id_raw: String) -> Dictionary:
	type_name = type_name.strip_edges()
	node_name = node_name.strip_edges()
	if type_name.is_empty() or node_name.is_empty():
		var err_args: Dictionary = {"ok": false, "error": "type and name are required"}
		return {
			"ok": false,
			"blocked": false,
			"skipped": false,
			"wrote": false,
			"error": err_args["error"],
			"log": "add_node failed: %s" % err_args["error"],
			"result": err_args,
		}
	var page_res: Dictionary = _require_page_id(page_id_raw)
	if not bool(page_res.get("ok", false)):
		return _page_id_failure("add_node", str(page_res.get("error", "page_id required")))
	var page_id: String = str(page_res.get("page_id", ""))
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		var err_scene: Dictionary = {"ok": false, "error": "no open scene"}
		return {
			"ok": false,
			"blocked": false,
			"skipped": false,
			"wrote": false,
			"error": "no open scene",
			"log": "add_node failed: no open scene",
			"result": err_scene,
		}
	if not ClassDB.class_exists(type_name):
		var err_type: Dictionary = {"ok": false, "error": "unknown type %s" % type_name}
		return {
			"ok": false,
			"blocked": false,
			"skipped": false,
			"wrote": false,
			"error": err_type["error"],
			"log": "add_node failed: %s" % err_type["error"],
			"result": err_type,
		}
	if not ClassDB.is_parent_class(type_name, &"Node"):
		var err_node: Dictionary = {"ok": false, "error": "%s is not a Node" % type_name}
		return {
			"ok": false,
			"blocked": false,
			"skipped": false,
			"wrote": false,
			"error": err_node["error"],
			"log": "add_node failed: %s" % err_node["error"],
			"result": err_node,
		}
	if root.has_node(NodePath(node_name)):
		var err_exists: Dictionary = {"ok": false, "error": "child %s already exists" % node_name}
		return {
			"ok": false,
			"blocked": false,
			"skipped": false,
			"wrote": false,
			"error": err_exists["error"],
			"log": "add_node failed: %s" % err_exists["error"],
			"result": err_exists,
		}

	var node: Node = ClassDB.instantiate(type_name) as Node
	if node == null:
		var err_inst: Dictionary = {"ok": false, "error": "could not instantiate %s" % type_name}
		return {
			"ok": false,
			"blocked": false,
			"skipped": false,
			"wrote": false,
			"error": err_inst["error"],
			"log": "add_node failed: %s" % err_inst["error"],
			"result": err_inst,
		}
	node.name = StringName(node_name)

	_ensure_action()
	var ur: EditorUndoRedoManager = EditorInterface.get_editor_undo_redo()
	# Apply now; commit_action(false) later so redo still works.
	root.add_child(node, true)
	node.owner = root
	node.set_meta(META_PAGE, page_id)
	ur.add_do_method(root, "add_child", node, true)
	ur.add_do_property(node, "owner", root)
	ur.add_do_method(node, "set_meta", META_PAGE, page_id)
	ur.add_undo_method(root, "remove_child", node)
	ur.add_do_reference(node)
	_note_page(page_id)
	_note_write(true)

	var payload: Dictionary = {
		"ok": true,
		"type": type_name,
		"name": str(node.name),
		"path": str(root.get_path_to(node)),
		"page_id": page_id,
	}
	return {
		"ok": true,
		"blocked": false,
		"skipped": false,
		"wrote": true,
		"error": "",
		"log": "add_node ok type=%s name=%s page_id=%s" % [type_name, str(node.name), page_id],
		"result": payload,
	}


func _set_property(
	path: String,
	property: String,
	value: Variant,
	page_id_raw: String
) -> Dictionary:
	path = path.strip_edges()
	property = property.strip_edges()
	if path.is_empty() or property.is_empty():
		var err_args: Dictionary = {"ok": false, "error": "path and property are required"}
		return {
			"ok": false,
			"blocked": false,
			"skipped": false,
			"wrote": false,
			"error": err_args["error"],
			"log": "set_property failed: %s" % err_args["error"],
			"result": err_args,
		}
	var page_res: Dictionary = _require_page_id(page_id_raw)
	if not bool(page_res.get("ok", false)):
		return _page_id_failure("set_property", str(page_res.get("error", "page_id required")))
	var page_id: String = str(page_res.get("page_id", ""))
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		var err_scene: Dictionary = {"ok": false, "error": "no open scene"}
		return {
			"ok": false,
			"blocked": false,
			"skipped": false,
			"wrote": false,
			"error": "no open scene",
			"log": "set_property failed: no open scene",
			"result": err_scene,
		}
	var node: Node = root.get_node_or_null(NodePath(path))
	if node == null:
		var err_path: Dictionary = {"ok": false, "error": "node not found: %s" % path}
		return {
			"ok": false,
			"blocked": false,
			"skipped": false,
			"wrote": false,
			"error": err_path["error"],
			"log": "set_property failed: %s" % err_path["error"],
			"result": err_path,
		}
	# Reject properties absent from the node snapshot (same filter as node_properties).
	if not _node_snapshot_has_property(node, property):
		var err_snap: Dictionary = {
			"ok": false,
			"error": "property absent from node snapshot: %s" % property,
		}
		return {
			"ok": false,
			"blocked": false,
			"skipped": false,
			"wrote": false,
			"error": err_snap["error"],
			"log": "set_property failed: %s" % err_snap["error"],
			"result": err_snap,
		}

	var coerced: Variant = _coerce_property_value(property, value)
	if typeof(coerced) == TYPE_DICTIONARY and bool((coerced as Dictionary).get("_error", false)):
		var err_coerce: Dictionary = {
			"ok": false,
			"error": str((coerced as Dictionary).get("error", "bad value")),
		}
		return {
			"ok": false,
			"blocked": false,
			"skipped": false,
			"wrote": false,
			"error": err_coerce["error"],
			"log": "set_property failed: %s" % err_coerce["error"],
			"result": err_coerce,
		}

	var old_value: Variant = node.get(property)
	var had_meta: bool = node.has_meta(META_PAGE)
	var old_meta: Variant = node.get_meta(META_PAGE) if had_meta else null
	_ensure_action()
	var ur: EditorUndoRedoManager = EditorInterface.get_editor_undo_redo()
	node.set(property, coerced)
	node.set_meta(META_PAGE, page_id)
	ur.add_do_property(node, property, coerced)
	ur.add_undo_property(node, property, old_value)
	ur.add_do_method(node, "set_meta", META_PAGE, page_id)
	if had_meta:
		ur.add_undo_method(node, "set_meta", META_PAGE, old_meta)
	else:
		ur.add_undo_method(node, "remove_meta", META_PAGE)
	_note_page(page_id)
	_note_write(true)

	var payload: Dictionary = {
		"ok": true,
		"path": path,
		"property": property,
		"value": value,
		"page_id": page_id,
	}
	return {
		"ok": true,
		"blocked": false,
		"skipped": false,
		"wrote": true,
		"error": "",
		"log": "set_property ok path=%s property=%s page_id=%s" % [path, property, page_id],
		"result": payload,
	}


func _coerce_property_value(property: String, value: Variant) -> Variant:
	## Load res:// paths for script (and similar Resource) properties.
	if property != "script":
		return value
	if value == null:
		return null
	if value is Script:
		return value
	var path: String = str(value).strip_edges()
	if path.is_empty():
		return null
	if not path.begins_with("res://"):
		return {
			"_error": true,
			"error": "script value must be a res:// path or Script resource",
		}
	if not FileAccess.file_exists(path):
		return {"_error": true, "error": "script file not found: %s" % path}
	# Ignore cache so a write_file in this same job is visible immediately.
	var loaded: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if loaded == null or not (loaded is Script):
		return {"_error": true, "error": "could not load Script at %s" % path}
	return loaded


func _list_pages() -> Dictionary:
	PageStoreScript.ensure_dirs()
	var pages: Array = PageStoreScript.list_pages()
	var payload: Dictionary = {"ok": true, "pages": pages}
	return {
		"ok": true,
		"blocked": false,
		"skipped": false,
		"wrote": false,
		"error": "",
		"log": "list_pages ok count=%d" % pages.size(),
		"result": payload,
	}


func _get_page(path_or_title: String) -> Dictionary:
	path_or_title = path_or_title.strip_edges()
	if path_or_title.is_empty():
		var err_args: Dictionary = {"ok": false, "error": "path is required"}
		return {
			"ok": false,
			"blocked": false,
			"skipped": false,
			"wrote": false,
			"error": err_args["error"],
			"log": "get_page failed: %s" % err_args["error"],
			"result": err_args,
		}
	var path: String = PageStoreScript.resolve_page_path(path_or_title)
	var page: Resource = null
	if not path.is_empty():
		page = PageStoreScript.load_page(path)
	if page == null:
		page = PageStoreScript.find_by_title(path_or_title)
	if page == null and path_or_title.begins_with("res://"):
		# Last chance: title from slug basename (goblin_shaman -> Goblin Shaman listing).
		page = PageStoreScript.find_by_title(
			path_or_title.get_file().get_basename().replace("_", " ")
		)
	if page == null:
		var err_missing: Dictionary = {
			"ok": false,
			"error": "page not found: %s" % path_or_title,
		}
		return {
			"ok": false,
			"blocked": false,
			"skipped": false,
			"wrote": false,
			"error": err_missing["error"],
			"log": "get_page failed: %s" % err_missing["error"],
			"result": err_missing,
		}
	var page_path: String = str(page.resource_path)
	var slug: String = page_path.get_file().get_basename()
	_note_page(slug)
	var payload: Dictionary = {
		"ok": true,
		"path": page_path,
		"title": str(page.get("title")),
		"kind": str(page.get("kind")),
		"notes": str(page.get("notes")),
		"tags": Array(PackedStringArray(page.get("tags"))),
		"image_paths": Array(PackedStringArray(page.get("image_paths"))),
		"links": Array(PackedStringArray(page.get("links"))),
		"page_id": slug,
	}
	return {
		"ok": true,
		"blocked": false,
		"skipped": false,
		"wrote": false,
		"error": "",
		"log": "get_page ok title=%s path=%s" % [payload["title"], payload["path"]],
		"result": payload,
	}


func _link(from_ref: String, to_ref: String) -> Dictionary:
	from_ref = from_ref.strip_edges()
	to_ref = to_ref.strip_edges()
	if from_ref.is_empty() or to_ref.is_empty():
		var err_args: Dictionary = {"ok": false, "error": "from and to are required"}
		return {
			"ok": false,
			"blocked": false,
			"skipped": false,
			"wrote": false,
			"error": err_args["error"],
			"log": "link failed: %s" % err_args["error"],
			"result": err_args,
		}
	var from_path: String = PageStoreScript.resolve_page_path(from_ref)
	var to_path: String = PageStoreScript.resolve_page_path(to_ref)
	if from_path.is_empty():
		from_path = from_ref
	if to_path.is_empty():
		to_path = to_ref

	_ensure_action()
	var ur: EditorUndoRedoManager = EditorInterface.get_editor_undo_redo()
	var outcome: Dictionary = _page_store.add_link(from_path, to_path)
	if not bool(outcome.get("ok", false)):
		return {
			"ok": false,
			"blocked": false,
			"skipped": false,
			"wrote": false,
			"error": str(outcome.get("error", "link failed")),
			"log": "link failed: %s" % str(outcome.get("error", "link failed")),
			"result": {"ok": false, "error": str(outcome.get("error", "link failed"))},
		}
	if bool(outcome.get("added", true)):
		ur.add_do_method(_page_store, "add_link", from_path, to_path)
		ur.add_undo_method(_page_store, "remove_link", from_path, to_path)
		ur.add_do_reference(_page_store)
		_note_write(false)
	var payload: Dictionary = {
		"ok": true,
		"from": from_path,
		"to": to_path,
		"added": bool(outcome.get("added", true)),
	}
	return {
		"ok": true,
		"blocked": false,
		"skipped": false,
		"wrote": bool(outcome.get("added", true)),
		"error": "",
		"log": "link ok from=%s to=%s" % [from_path, to_path],
		"result": payload,
	}


func _list_dir(path: String) -> Dictionary:
	var gate: Dictionary = _require_page_scoped_path(path)
	if not bool(gate.get("ok", false)):
		return {
			"ok": false,
			"blocked": false,
			"skipped": false,
			"wrote": false,
			"error": str(gate.get("error", "path not allowed")),
			"log": "list_dir failed: %s" % str(gate.get("error", "")),
			"result": {"ok": false, "error": str(gate.get("error", ""))},
		}
	var listed: Dictionary = FileSupportScript.list_dir(str(gate.get("path", path)))
	if not bool(listed.get("ok", false)):
		return {
			"ok": false,
			"blocked": false,
			"skipped": false,
			"wrote": false,
			"error": str(listed.get("error", "list_dir failed")),
			"log": "list_dir failed: %s" % str(listed.get("error", "")),
			"result": {"ok": false, "error": str(listed.get("error", ""))},
		}
	var entries: Array = listed.get("entries", [])
	var payload: Dictionary = {
		"ok": true,
		"path": str(listed.get("path", path)),
		"entries": entries,
	}
	return {
		"ok": true,
		"blocked": false,
		"skipped": false,
		"wrote": false,
		"error": "",
		"log": "list_dir ok path=%s count=%d" % [payload["path"], entries.size()],
		"result": payload,
	}


func _read_file(path: String) -> Dictionary:
	var gate: Dictionary = _require_page_scoped_path(path)
	if not bool(gate.get("ok", false)):
		return {
			"ok": false,
			"blocked": false,
			"skipped": false,
			"wrote": false,
			"error": str(gate.get("error", "path not allowed")),
			"log": "read_file failed: %s" % str(gate.get("error", "")),
			"result": {"ok": false, "error": str(gate.get("error", ""))},
		}
	var read_out: Dictionary = FileSupportScript.read_text_file(str(gate.get("path", path)))
	if not bool(read_out.get("ok", false)):
		return {
			"ok": false,
			"blocked": false,
			"skipped": false,
			"wrote": false,
			"error": str(read_out.get("error", "read_file failed")),
			"log": "read_file failed: %s" % str(read_out.get("error", "")),
			"result": {"ok": false, "error": str(read_out.get("error", ""))},
		}
	var payload: Dictionary = {
		"ok": true,
		"path": str(read_out.get("path", path)),
		"content": str(read_out.get("content", "")),
	}
	return {
		"ok": true,
		"blocked": false,
		"skipped": false,
		"wrote": false,
		"error": "",
		"log": "read_file ok path=%s bytes=%d" % [
			payload["path"],
			str(payload["content"]).length(),
		],
		"result": payload,
	}


func _write_file(path: String, content: String, page_id_raw: String = "") -> Dictionary:
	var preview_path: String = path.strip_edges()
	var needs_page: bool = FileSupportScript.triggers_play_gate(preview_path)
	var page_id: String = ""
	if needs_page:
		var page_res: Dictionary = _require_page_id(page_id_raw)
		if not bool(page_res.get("ok", false)):
			return _page_id_failure("write_file", str(page_res.get("error", "page_id required")))
		page_id = str(page_res.get("page_id", ""))

	var wrote_out: Dictionary = FileSupportScript.write_text_file(path, content)
	if not bool(wrote_out.get("ok", false)):
		return {
			"ok": false,
			"blocked": false,
			"skipped": false,
			"wrote": false,
			"error": str(wrote_out.get("error", "write_file failed")),
			"log": "write_file failed: %s" % str(wrote_out.get("error", "")),
			"result": {"ok": false, "error": str(wrote_out.get("error", ""))},
		}
	var res_path: String = str(wrote_out.get("path", path))
	var existed: bool = bool(wrote_out.get("existed", false))
	var previous: String = str(wrote_out.get("previous", ""))

	_ensure_action()
	var ur: EditorUndoRedoManager = EditorInterface.get_editor_undo_redo()
	ur.add_do_method(_file_store, "apply_write", res_path, content)
	ur.add_undo_method(_file_store, "undo_write", res_path, previous, existed)
	ur.add_do_reference(_file_store)
	if not page_id.is_empty():
		_note_page(page_id)
	_note_write(FileSupportScript.triggers_play_gate(res_path))

	var fs: EditorFileSystem = EditorInterface.get_resource_filesystem()
	if fs != null:
		fs.update_file(res_path)
		fs.scan()

	var payload: Dictionary = {
		"ok": true,
		"path": res_path,
		"created": not existed,
		"page_id": page_id,
	}
	return {
		"ok": true,
		"blocked": false,
		"skipped": false,
		"wrote": true,
		"error": "",
		"log": "write_file ok path=%s created=%s page_id=%s" % [
			res_path, str(not existed), page_id
		],
		"result": payload,
	}


func _delete_file(path: String) -> Dictionary:
	var deleted: Dictionary = FileSupportScript.delete_text_file(path)
	var res_path: String = str(deleted.get("path", path))
	if not bool(deleted.get("ok", false)):
		return {
			"ok": false,
			"blocked": false,
			"skipped": false,
			"wrote": false,
			"error": str(deleted.get("error", "delete_file failed")),
			"log": "delete_file failed path=%s: %s" % [res_path, str(deleted.get("error", ""))],
			"result": {"ok": false, "error": str(deleted.get("error", "")), "path": res_path},
		}
	var previous: String = str(deleted.get("previous", ""))

	_ensure_action()
	var ur: EditorUndoRedoManager = EditorInterface.get_editor_undo_redo()
	ur.add_do_method(_file_store, "apply_delete", res_path)
	ur.add_undo_method(_file_store, "undo_delete", res_path, previous)
	ur.add_do_reference(_file_store)
	_note_write(FileSupportScript.triggers_play_gate(res_path))

	if EditorInterface.get_resource_filesystem() != null:
		EditorInterface.get_resource_filesystem().scan()

	var payload: Dictionary = {"ok": true, "path": res_path}
	return {
		"ok": true,
		"blocked": false,
		"skipped": false,
		"wrote": true,
		"error": "",
		"log": "delete_file ok path=%s" % res_path,
		"result": payload,
	}


func _record_op(tool_name: String, args: Dictionary) -> void:
	## Session jsonl gets op name + page id — never a class_get dump or secrets.
	var summary: Dictionary = {"tool": tool_name}
	if tool_name == "class_get":
		var cls: String = str(args.get("class", args.get("name", args.get("type", "")))).strip_edges()
		if not cls.is_empty():
			summary["class"] = cls
		ops_log.append(summary)
		return
	for key: String in ["page_id", "path", "name", "type", "property", "character", "from", "to", "target", "class"]:
		if args.has(key):
			summary[key] = args[key]
	ops_log.append(summary)


func _node_snapshot_has_property(node: Node, property: String) -> bool:
	## Same property filter as node_properties / class_get storage+editor props.
	if node == null or property.strip_edges().is_empty():
		return false
	for info: Dictionary in node.get_property_list():
		var pname: String = str(info.get("name", ""))
		if pname != property:
			continue
		var usage: int = int(info.get("usage", 0))
		if (usage & PROPERTY_USAGE_CATEGORY) != 0:
			continue
		if (usage & PROPERTY_USAGE_GROUP) != 0 or (usage & PROPERTY_USAGE_SUBGROUP) != 0:
			continue
		if (usage & PROPERTY_USAGE_STORAGE) == 0 and (usage & PROPERTY_USAGE_EDITOR) == 0:
			continue
		return true
	return false


func _require_page_scoped_path(path: String) -> Dictionary:
	## list_dir / read_file: only paths a cited page points at (not project-wide search).
	if cited_page_ids.is_empty():
		return {
			"ok": false,
			"error": "cite a page with get_page before list_dir/read_file",
			"path": "",
		}
	var norm: Dictionary = FileSupportScript.normalize_res_path(
		path if not path.strip_edges().is_empty() else "res://"
	)
	if not bool(norm.get("ok", false)):
		return {"ok": false, "error": str(norm.get("error", "bad path")), "path": ""}
	var res_path: String = str(norm["path"])
	var allowed: PackedStringArray = _cited_page_paths()
	if allowed.is_empty():
		return {
			"ok": false,
			"error": "cited pages have no readable paths yet — call get_page first",
			"path": "",
		}
	for root_path: String in allowed:
		if res_path == root_path:
			return {"ok": true, "path": res_path, "error": ""}
		var prefix: String = root_path if root_path.ends_with("/") else root_path + "/"
		if res_path.begins_with(prefix):
			return {"ok": true, "path": res_path, "error": ""}
		# Allow listing the directory that contains a pointed-at file.
		if root_path.begins_with(res_path.rstrip("/") + "/") or root_path.get_base_dir() == res_path.rstrip("/"):
			return {"ok": true, "path": res_path, "error": ""}
	return {
		"ok": false,
		"error": "path not pointed at by a cited page: %s" % res_path,
		"path": "",
	}


func _cited_page_paths() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for pid: String in cited_page_ids:
		var resolved: String = PageStoreScript.resolve_page_path(pid)
		if resolved.is_empty():
			continue
		_append_unique_path(out, resolved)
		_append_unique_path(out, resolved.get_base_dir())
		var page: Resource = PageStoreScript.load_page(resolved)
		if page == null:
			continue
		for img: String in PackedStringArray(page.get("image_paths")):
			var ip: String = str(img).strip_edges()
			if ip.is_empty():
				continue
			_append_unique_path(out, ip)
			_append_unique_path(out, ip.get_base_dir())
		for link: String in PackedStringArray(page.get("links")):
			var lp: String = str(link).strip_edges()
			if lp.is_empty():
				continue
			var link_resolved: String = PageStoreScript.resolve_page_path(lp)
			if link_resolved.is_empty():
				link_resolved = lp
			_append_unique_path(out, link_resolved)
			_append_unique_path(out, link_resolved.get_base_dir())
	return out


func _append_unique_path(out: PackedStringArray, path: String) -> void:
	var p: String = path.strip_edges().replace("\\", "/")
	if p.is_empty():
		return
	if not p.begins_with("res://"):
		return
	for existing: String in out:
		if existing == p:
			return
	out.append(p)


func _note_page(page_id: String) -> void:
	var pid: String = page_id.strip_edges()
	if pid.is_empty():
		return
	for existing: String in cited_page_ids:
		if existing == pid:
			return
	cited_page_ids.append(pid)


func _require_page_id(raw: String) -> Dictionary:
	## Resolve page_id before any undo-redo. Reject if missing or unknown.
	var s: String = raw.strip_edges()
	if s.is_empty():
		return {"ok": false, "error": "page_id is required", "page_id": ""}
	# Accept slug, title, or res:// path that resolves to a studio page.
	var resolved: String = PageStoreScript.resolve_page_path(s)
	if resolved.is_empty():
		# Try slug as filename under characters/assets.
		var slug: String = PageStoreScript.slugify(s)
		for kind: String in ["character", "asset"]:
			var candidate: String = "%s/%s.tres" % [PageStoreScript.dir_for_kind(kind), slug]
			if ResourceLoader.exists(candidate) or FileAccess.file_exists(candidate):
				return {"ok": true, "page_id": slug, "path": candidate}
		return {"ok": false, "error": "unknown page_id: %s" % s, "page_id": ""}
	var page: Resource = PageStoreScript.load_page(resolved)
	var slug_out: String = PageStoreScript.slugify(str(page.get("title")) if page != null else s)
	if slug_out.is_empty():
		slug_out = resolved.get_file().get_basename()
	return {"ok": true, "page_id": slug_out, "path": resolved}


func _page_id_failure(tool_name: String, message: String) -> Dictionary:
	return {
		"ok": false,
		"blocked": false,
		"skipped": false,
		"wrote": false,
		"error": message,
		"log": "%s failed: %s" % [tool_name, message],
		"result": {"ok": false, "error": message},
	}


func _check_page_drift(page_id_raw: String) -> Dictionary:
	## Read-only drift findings. Never rewrites the scene.
	var page_res: Dictionary = _require_page_id(page_id_raw)
	if not bool(page_res.get("ok", false)):
		return _page_id_failure("check_page_drift", str(page_res.get("error", "page_id required")))
	var page_id: String = str(page_res.get("page_id", ""))
	var root: Node = EditorInterface.get_edited_scene_root()
	var findings: Array = []
	if root == null:
		findings.append({
			"kind": "no_scene",
			"message": "no open scene to compare",
		})
	else:
		var owned: Array = []
		_collect_page_nodes(root, page_id, owned)
		if owned.is_empty():
			findings.append({
				"kind": "missing_nodes",
				"message": "no nodes with agentic_page=%s in the open scene" % page_id,
			})
		else:
			for item: Variant in owned:
				if typeof(item) != TYPE_DICTIONARY:
					continue
				var d: Dictionary = item
				findings.append({
					"kind": "owned",
					"path": str(d.get("path", "")),
					"name": str(d.get("name", "")),
					"class": str(d.get("class", "")),
					"message": "node present",
				})
	var payload: Dictionary = {
		"ok": true,
		"page_id": page_id,
		"findings": findings,
		"drift": not findings.is_empty() and str((findings[0] as Dictionary).get("kind", "")) != "owned",
	}
	# drift true when missing_nodes / no_scene; owned-only is not drift.
	var has_problem: bool = false
	for f: Variant in findings:
		if typeof(f) == TYPE_DICTIONARY:
			var k: String = str((f as Dictionary).get("kind", ""))
			if k != "owned":
				has_problem = true
				break
	payload["drift"] = has_problem
	return {
		"ok": true,
		"blocked": false,
		"skipped": false,
		"wrote": false,
		"error": "",
		"log": "check_page_drift page_id=%s findings=%d drift=%s" % [
			page_id, findings.size(), str(has_problem)
		],
		"result": payload,
	}


func _collect_page_nodes(node: Node, page_id: String, out: Array) -> void:
	if node == null:
		return
	if node.has_meta(META_PAGE) and str(node.get_meta(META_PAGE)) == page_id:
		var root: Node = EditorInterface.get_edited_scene_root()
		var rel: String = str(node.name)
		if root != null and node != root:
			rel = str(root.get_path_to(node))
		out.append({
			"name": str(node.name),
			"path": rel,
			"class": node.get_class(),
		})
	for i: int in range(node.get_child_count()):
		_collect_page_nodes(node.get_child(i), page_id, out)
