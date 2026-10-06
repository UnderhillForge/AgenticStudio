class_name AgenticStudioApplyServer
extends Node
## Loopback TCP JSON-line apply API for the sidecar. Never writes project.godot/autoloads itself
## except through the play sensor's temporary PlayProbe toggle.

const DEFAULT_PORT: int = 8765
const BIND_HOST: String = "127.0.0.1"

var _server: TCPServer = TCPServer.new()
var _clients: Array = []
var _port: int = DEFAULT_PORT
var _buf: Dictionary = {} # peer_id -> String


func start(port: int = DEFAULT_PORT) -> Error:
	_port = port
	var err: Error = _server.listen(_port, BIND_HOST)
	if err != OK:
		push_warning("AgenticStudio apply_server: listen failed on %d (%d)" % [_port, err])
		return err
	print("AgenticStudio apply_server: listening on %s:%d" % [BIND_HOST, _port])
	set_process(true)
	return OK


func stop() -> void:
	set_process(false)
	for peer: Variant in _clients:
		if peer is StreamPeerTCP:
			(peer as StreamPeerTCP).disconnect_from_host()
	_clients.clear()
	_buf.clear()
	if _server.is_listening():
		_server.stop()


func _process(_delta: float) -> void:
	if _server.is_listening() and _server.is_connection_available():
		var peer: StreamPeerTCP = _server.take_connection()
		if peer != null:
			_clients.append(peer)
			_buf[peer.get_instance_id()] = ""
	var dead: Array = []
	for peer2: Variant in _clients:
		if not (peer2 is StreamPeerTCP):
			dead.append(peer2)
			continue
		var tcp: StreamPeerTCP = peer2 as StreamPeerTCP
		tcp.poll()
		var st: int = tcp.get_status()
		if st != StreamPeerTCP.STATUS_CONNECTED:
			dead.append(tcp)
			continue
		var avail: int = tcp.get_available_bytes()
		if avail <= 0:
			continue
		var chunk: String = tcp.get_utf8_string(avail)
		var id: int = tcp.get_instance_id()
		var acc: String = str(_buf.get(id, "")) + chunk
		while true:
			var nl: int = acc.find("\n")
			if nl < 0:
				break
			var line: String = acc.substr(0, nl).strip_edges()
			acc = acc.substr(nl + 1)
			if not line.is_empty():
				_handle_line(tcp, line)
		_buf[id] = acc
	for d: Variant in dead:
		var did: int = (d as Object).get_instance_id() if d is Object else 0
		_buf.erase(did)
		_clients.erase(d)
		if d is StreamPeerTCP:
			(d as StreamPeerTCP).disconnect_from_host()


func _handle_line(tcp: StreamPeerTCP, line: String) -> void:
	var parsed: Variant = JSON.parse_string(line)
	if typeof(parsed) != TYPE_DICTIONARY:
		_reply(tcp, {"id": null, "ok": false, "error": "invalid json"})
		return
	var req: Dictionary = parsed
	var req_id: Variant = req.get("id", null)
	var method: String = str(req.get("method", "")).strip_edges()
	var params: Dictionary = {}
	if typeof(req.get("params", {})) == TYPE_DICTIONARY:
		params = req.get("params", {})
	var result: Dictionary = await _dispatch(method, params)
	result["id"] = req_id
	_reply(tcp, result)


func _reply(tcp: StreamPeerTCP, payload: Dictionary) -> void:
	var text: String = JSON.stringify(payload) + "\n"
	tcp.put_data(text.to_utf8_buffer())


func _dispatch(method: String, params: Dictionary) -> Dictionary:
	match method:
		"ping":
			return {"ok": true, "result": {"pong": true, "port": _port}}
		"list_pages":
			return _call_tool("list_pages", params, false)
		"get_page":
			return _call_tool("get_page", params, false)
		"read_scene":
			return _call_tool("read_scene", params, false)
		"check_page_drift":
			return _call_tool("check_page_drift", params, false)
		"apply_ops":
			return await _apply_ops(params)
		"undo_job":
			return _undo_once()
		_:
			return {"ok": false, "error": "unknown method: %s" % method}


func _call_tool(tool_name: String, args: Dictionary, _write: bool) -> Dictionary:
	var tools := AgenticStudioSceneTools.new()
	tools.setup("apply_server")
	var outcome: Dictionary = tools.execute(tool_name, args)
	return {
		"ok": bool(outcome.get("ok", false)),
		"result": outcome.get("result", {}),
		"error": str(outcome.get("error", "")),
		"log": str(outcome.get("log", "")),
	}


func _apply_ops(params: Dictionary) -> Dictionary:
	var PolicyScript = preload("res://addons/agentic_studio/policy.gd")
	var SessionLogScript = preload("res://addons/agentic_studio/session_log.gd")
	var job_id: String = str(params.get("job_id", "sidecar_%d" % Time.get_unix_time_from_system()))
	var mode: String = str(params.get("mode", "auto_approve"))
	var ops: Array = params.get("ops", [])
	var model_id: String = str(params.get("model_id", "sidecar"))
	var tools := AgenticStudioSceneTools.new()
	tools.setup(job_id)
	var results: Array = []
	var logged_ops: Array = []
	var ask_writes: bool = mode == "run"
	for op_v: Variant in ops:
		if typeof(op_v) != TYPE_DICTIONARY:
			continue
		var op: Dictionary = op_v
		var tool_name: String = str(op.get("tool", op.get("name", "")))
		var args: Dictionary = {}
		if typeof(op.get("arguments", op.get("args", {}))) == TYPE_DICTIONARY:
			args = op.get("arguments", op.get("args", {}))
		logged_ops.append({"tool": tool_name, "arguments": args})
		if not AgenticStudioSceneTools.is_allowed_tool(tool_name):
			results.append({"tool": tool_name, "ok": false, "error": "blocked"})
			continue
		if PolicyScript.classify(tool_name, args) == PolicyScript.DECISION_REJECT:
			results.append({"tool": tool_name, "ok": false, "error": "rejected by policy"})
			continue
		if mode == "auto_approve" and not PolicyScript.is_allowed_unattended(tool_name, args):
			results.append({
				"tool": tool_name,
				"ok": false,
				"error": "needs_confirm",
				"needs_confirm": true,
			})
			continue
		if ask_writes and AgenticStudioSceneTools.is_write_tool(tool_name):
			# Sidecar Run mode still requires an explicit confirm flag per op.
			if not bool(op.get("confirmed", false)) and PolicyScript.needs_confirm(tool_name, args):
				results.append({
					"tool": tool_name,
					"ok": false,
					"error": "needs_confirm",
					"needs_confirm": true,
				})
				continue
		var outcome: Dictionary
		if tool_name == AgenticStudioSceneTools.TOOL_PLAY_SCENE:
			outcome = await tools.execute_play()
		elif tool_name == AgenticStudioSceneTools.TOOL_CREATE_ASSET:
			outcome = await tools.execute_create_asset(args)
		elif tool_name == AgenticStudioSceneTools.TOOL_SCREENSHOT:
			outcome = await tools.execute_screenshot(args)
		else:
			outcome = tools.execute(tool_name, args)
		results.append({
			"tool": tool_name,
			"ok": bool(outcome.get("ok", false)),
			"result": outcome.get("result", {}),
			"log": str(outcome.get("log", "")),
			"error": str(outcome.get("error", "")),
		})
	var play: Variant = null
	if tools.has_scene_writes():
		var play_out: Dictionary = await tools.execute_play()
		play = play_out.get("result", {})
	tools.finish()
	# Prefer executed ops_log; fall back to requested ops (needs_confirm / rejects).
	var ops_for_log: Array = tools.ops_log if not tools.ops_log.is_empty() else logged_ops
	SessionLogScript.append_plan_or_run(
		model_id,
		mode,
		tools.cited_page_ids,
		ops_for_log,
		play
	)
	return {
		"ok": true,
		"result": {
			"job_id": job_id,
			"ops": results,
			"play": play,
			"page_ids": Array(tools.cited_page_ids),
		},
	}


func _undo_once() -> Dictionary:
	var root: Node = EditorInterface.get_edited_scene_root()
	var ur_mgr: EditorUndoRedoManager = EditorInterface.get_editor_undo_redo()
	if root == null:
		return {"ok": false, "error": "no open scene"}
	var history_id: int = ur_mgr.get_object_history_id(root)
	var ur: UndoRedo = ur_mgr.get_history_undo_redo(history_id)
	if ur == null or not ur.has_undo():
		return {"ok": false, "error": "nothing to undo"}
	ur.undo()
	return {"ok": true, "result": {"undone": true}}
