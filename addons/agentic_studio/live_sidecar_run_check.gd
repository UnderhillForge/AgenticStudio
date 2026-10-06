class_name AgenticStudioLiveSidecarRunCheck
extends RefCounted
## Live harness: runtime-fail scene + sidecar run (one fix); needs_confirm; missing page_id.

const SessionLogScript = preload("res://addons/agentic_studio/session_log.gd")
const PAGE_ID: String = "goblin_shaman"
const BOOM_SCRIPT: String = "res://harness_boom.gd"
const DEFAULT_BASE: String = "http://192.168.68.55:11434/v1"
const DEFAULT_MODEL: String = "qwen2.5-coder:7b"


func run() -> Dictionary:
	var failures: PackedStringArray = PackedStringArray()
	AgenticStudioConfig.ensure_dirs()
	SessionLogScript.ensure_dirs()

	var scene_path: String = "res://agent_probe_scene.tscn"
	_ensure_probe_scene(scene_path)
	EditorInterface.open_scene_from_path(scene_path)
	# Avoid set_main_screen_editor here — macOS Godot can crash with
	# NSInternalInconsistencyException (menu edit off main thread) during live boots.
	await _frames(6)
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return {"ok": false, "failures": PackedStringArray(["no open scene"])}

	_remove_child_named(root, "BoomProbe")
	_remove_child_named(root, "Marker")
	_remove_child_named(root, "HarnessMarker")

	# Script parses; runtime fails while `arm` is true. Fix = set_property arm=false (allow).
	_write_text(
		BOOM_SCRIPT,
		(
			"extends Node3D\n"
			+ "@export var arm: bool = true\n"
			+ "func _ready() -> void:\n"
			+ "\tif arm:\n"
			+ "\t\tvar n = null\n"
			+ "\t\tprint(n.name)\n"
		)
	)
	EditorInterface.get_resource_filesystem().scan()
	await _frames(2)

	var prep := AgenticStudioSceneTools.new()
	prep.setup("live_sidecar_prep")
	var add_boom: Dictionary = prep.execute(
		AgenticStudioSceneTools.TOOL_ADD_NODE,
		{"type": "Node3D", "name": "BoomProbe", "page_id": PAGE_ID}
	)
	if not bool(add_boom.get("ok", false)):
		failures.append("prep add BoomProbe failed: %s" % str(add_boom.get("error", "")))
	var set_script: Dictionary = prep.execute(
		AgenticStudioSceneTools.TOOL_SET_PROPERTY,
		{
			"path": "BoomProbe",
			"property": "script",
			"value": BOOM_SCRIPT,
			"page_id": PAGE_ID,
		}
	)
	if not bool(set_script.get("ok", false)):
		failures.append("prep attach boom script failed: %s" % str(set_script.get("error", "")))
	prep.execute(
		AgenticStudioSceneTools.TOOL_SET_PROPERTY,
		{"path": "BoomProbe", "property": "arm", "value": true, "page_id": PAGE_ID}
	)
	prep.finish()
	EditorInterface.save_scene()
	await _frames(2)

	# --- Missing page_id: reject, no second apply (plugin path) ---
	var reject_tools := AgenticStudioSceneTools.new()
	reject_tools.setup("live_sidecar_nopage")
	var before: int = _child_count(EditorInterface.get_edited_scene_root())
	var no_page: Dictionary = reject_tools.execute(
		AgenticStudioSceneTools.TOOL_ADD_NODE,
		{"type": "Node3D", "name": "NoPageMarker"}
	)
	if bool(no_page.get("ok", false)):
		failures.append("missing page_id must be rejected")
	if str(no_page.get("error", "")).find("page_id") < 0 \
			and str(no_page.get("log", "")).find("page_id") < 0:
		failures.append("missing page_id error unclear")
	if _child_count(EditorInterface.get_edited_scene_root()) != before:
		failures.append("missing page_id reject still mutated the scene")

	# --- Script-body op → needs_confirm via apply server policy ---
	var PolicyScript = preload("res://addons/agentic_studio/policy.gd")
	if not PolicyScript.needs_confirm("write_file", {"path": "res://harness_fix.gd"}):
		failures.append("script-body write_file must needs_confirm")
	var apply_peer: Dictionary = await _apply_ops_tcp([
		{
			"tool": "write_file",
			"arguments": {
				"path": "res://harness_fix.gd",
				"content": "extends Node\n",
				"page_id": PAGE_ID,
			},
		}
	], "auto_approve", "live_confirm")
	var confirm_ops: Array = []
	if typeof(apply_peer.get("result", {})) == TYPE_DICTIONARY:
		confirm_ops = (apply_peer["result"] as Dictionary).get("ops", [])
	var saw_confirm: bool = false
	for item: Variant in confirm_ops:
		if typeof(item) == TYPE_DICTIONARY and (
			bool((item as Dictionary).get("needs_confirm", false))
			or str((item as Dictionary).get("error", "")) == "needs_confirm"
		):
			saw_confirm = true
	if not saw_confirm:
		failures.append("script-body apply must return needs_confirm: %s" % JSON.stringify(apply_peer))
	if FileAccess.file_exists(ProjectSettings.globalize_path("res://harness_fix.gd")):
		failures.append("needs_confirm write_file must not create the file")
		DirAccess.remove_absolute(ProjectSettings.globalize_path("res://harness_fix.gd"))

	# --- Sidecar run: first op should play-fail; fix sets arm=false ---
	var base_url: String = DEFAULT_BASE
	var model_name: String = DEFAULT_MODEL
	if not _ollama_up(base_url):
		var selected_id: String = AgenticStudioConfig.get_selected_model_id()
		var model: Dictionary = AgenticStudioConfig.get_model(selected_id)
		if not model.is_empty():
			base_url = str(model.get("base_url", base_url))
			model_name = str(model.get("model_name", model_name))
			failures.append("WARN: default Ollama host down; using configured %s" % model_name)
		else:
			failures.append("no model host available for sidecar run")
			return {"ok": false, "failures": failures}

	var jsonl_path: String = SessionLogScript.path_for_day()
	var abs_jsonl: String = ProjectSettings.globalize_path(jsonl_path)
	var lines_before: int = _count_jsonl_lines(abs_jsonl)

	var out_path: String = OS.get_temp_dir().path_join("agentic_sidecar_run_out.json")
	if FileAccess.file_exists(out_path):
		DirAccess.remove_absolute(out_path)
	var prompt: String = (
		"The open scene has BoomProbe with export arm=true; its _ready crashes while arm is true. "
		+ "Reply with exactly this shape of op (fill page_id): "
		+ '{"tool":"add_node","arguments":{"type":"Node3D","name":"HarnessMarker","page_id":"%s"}}. ' % PAGE_ID
		+ "Do not change BoomProbe on the first op. Keys must be type and name (not node_type/node_name)."
	)
	var sidecar_dir: String = ProjectSettings.globalize_path("res://sidecar")
	var cmd: PackedStringArray = PackedStringArray([
		"uv", "run", "agentic-sidecar", "run",
		"--prompt", prompt,
		"--base-url", base_url,
		"--model", model_name,
		"--mode", "auto_approve",
		"--page-id", PAGE_ID,
		"--model-id", "live_sidecar_run",
	])
	# Non-blocking spawn: blocking OS.execute freezes the main thread so the apply
	# TCP server never polls and the sidecar deadlocks waiting on :8765.
	var shell: String = "cd %s && %s > %s 2>&1; echo EXIT:$? >> %s" % [
		_shell_quote(sidecar_dir),
		" ".join(_shell_quote_each(cmd)),
		_shell_quote(out_path),
		_shell_quote(out_path),
	]
	var pid: int = OS.create_process("/bin/bash", PackedStringArray(["-lc", shell]), false)
	if pid <= 0:
		failures.append("failed to spawn sidecar run process")
		return {"ok": false, "failures": failures, "sidecar_out": out_path}
	var wait_deadline: int = Time.get_ticks_msec() + 240000
	while OS.is_process_running(pid) and Time.get_ticks_msec() < wait_deadline:
		await _frames(1)
	if OS.is_process_running(pid):
		OS.kill(pid)
		failures.append("sidecar run timed out")
	var run_text: String = ""
	if FileAccess.file_exists(out_path):
		run_text = FileAccess.get_file_as_string(out_path)
	var exit_code: int = -1
	var exit_marker: int = run_text.rfind("EXIT:")
	if exit_marker >= 0:
		exit_code = int(run_text.substr(exit_marker + 5).strip_edges().get_slice("\n", 0))
	var run_json: Dictionary = _extract_json_object(run_text)
	if run_json.is_empty():
		failures.append("sidecar run produced no JSON (exit=%d): %s" % [exit_code, run_text.substr(0, 500)])
	else:
		var attempts: Array = run_json.get("attempts", [])
		if attempts.size() < 2:
			# Model may fix on first try if it ignored instructions — still require play fail then fix ideally.
			# Accept fixed-on-first only if play ended ok and BoomProbe.arm is false; else fail.
			if attempts.size() == 1 and bool(run_json.get("ok", false)):
				failures.append("expected fail-then-fix (2 applies); got single successful attempt")
			elif attempts.size() < 2:
				failures.append("expected 2 attempts (fail+fix), got %d: %s" % [
					attempts.size(), JSON.stringify(run_json).substr(0, 800)
				])
		else:
			var play1: Variant = ((attempts[0] as Dictionary).get("flags", {}) as Dictionary).get("play", null)
			if typeof(play1) != TYPE_DICTIONARY or bool((play1 as Dictionary).get("ok", true)):
				failures.append("first apply should have play ok=false")
			var fix_op: Dictionary = (attempts[1] as Dictionary).get("op", {}) as Dictionary
			var fix_tool: String = str(fix_op.get("tool", ""))
			if fix_tool.is_empty():
				failures.append("second attempt missing fix op")
			# Prefer a real fix (set_property arm=false). Re-adding the same node is a weak fix.
			var outcome: String = str(run_json.get("outcome", ""))
			if outcome not in ["ok", "fixed", "fix_failed"]:
				failures.append("unexpected harness outcome: %s" % outcome)
		root = EditorInterface.get_edited_scene_root()
		var boom: Node = root.get_node_or_null(NodePath("BoomProbe")) if root else null
		if boom != null and bool(boom.get("arm")):
			# If harness claimed fixed/ok, arm must be false.
			if bool(run_json.get("ok", false)):
				failures.append("BoomProbe.arm still true after successful harness")

	var lines_after: int = _count_jsonl_lines(abs_jsonl)
	if lines_after < lines_before + 1:
		failures.append("session jsonl did not grow (before=%d after=%d)" % [lines_before, lines_after])
	else:
		var tail: PackedStringArray = _jsonl_tail(abs_jsonl, mini(4, lines_after - lines_before + 1))
		var joined: String = "\n".join(tail)
		if joined.find("live_sidecar_run") < 0 and joined.find(model_name) < 0:
			failures.append("jsonl tail missing model id from sidecar run")
		# Expect evidence of play results in recent lines.
		if joined.find("\"play\"") < 0 and joined.find("phase") < 0:
			failures.append("jsonl missing play result fields")

	if ProjectSettings.has_setting("autoload/PlayProbe"):
		failures.append("PlayProbe leaked into project settings")
	if FileAccess.file_exists(ProjectSettings.globalize_path("res://override.cfg")):
		# May be empty leftover — treat as leak if PlayProbe mentioned.
		var ov: String = FileAccess.get_file_as_string("res://override.cfg")
		if ov.find("PlayProbe") >= 0:
			failures.append("PlayProbe left in override.cfg")

	# Each apply is one undo action. Fail+fix ⇒ two undos clear the run.
	root = EditorInterface.get_edited_scene_root()
	if root != null:
		var boom_before: Node = root.get_node_or_null(NodePath("BoomProbe"))
		var arm_was_false: bool = boom_before != null and not bool(boom_before.get("arm"))
		_undo_once(root)
		await _frames(2)
		root = EditorInterface.get_edited_scene_root()
		var boom_mid: Node = root.get_node_or_null(NodePath("BoomProbe")) if root else null
		if arm_was_false and boom_mid != null and not bool(boom_mid.get("arm")):
			failures.append("one undo did not revert last fix (BoomProbe.arm)")
		# Second undo clears the first apply (HarnessMarker).
		_undo_once(root)
		await _frames(2)
		root = EditorInterface.get_edited_scene_root()
		if root != null and root.get_node_or_null(NodePath("HarnessMarker")) != null:
			failures.append("two undos did not remove sidecar HarnessMarker")

	# Cleanup boom prep (may take another undo or direct remove).
	root = EditorInterface.get_edited_scene_root()
	_remove_child_named(root, "HarnessMarker")
	_remove_child_named(root, "Marker")
	_remove_child_named(root, "BoomProbe")
	if FileAccess.file_exists(ProjectSettings.globalize_path(BOOM_SCRIPT)):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(BOOM_SCRIPT))
	EditorInterface.save_scene()

	# Drop WARN lines from hard failures list for ok decision.
	var hard: PackedStringArray = PackedStringArray()
	for f: String in failures:
		if f.begins_with("WARN:"):
			print("AgenticStudio live_sidecar_run: ", f)
		else:
			hard.append(f)

	return {
		"ok": hard.is_empty(),
		"failures": hard,
		"sidecar_out": out_path,
	}


func _apply_ops_tcp(ops: Array, mode: String, model_id: String) -> Dictionary:
	## Talk to the in-process apply server the same way the sidecar does.
	var payload: Dictionary = {
		"id": 1,
		"method": "apply_ops",
		"params": {"ops": ops, "mode": mode, "model_id": model_id, "job_id": model_id},
	}
	var peer := StreamPeerTCP.new()
	var err: Error = peer.connect_to_host("127.0.0.1", 8765)
	if err != OK:
		return {"ok": false, "error": "connect failed %d" % err}
	var deadline: int = Time.get_ticks_msec() + 5000
	while peer.get_status() != StreamPeerTCP.STATUS_CONNECTED and Time.get_ticks_msec() < deadline:
		peer.poll()
		await _frames(1)
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return {"ok": false, "error": "not connected"}
	var line: String = JSON.stringify(payload) + "\n"
	peer.put_data(line.to_utf8_buffer())
	var buf: String = ""
	var read_deadline: int = Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < read_deadline:
		peer.poll()
		var n: int = peer.get_available_bytes()
		if n > 0:
			buf += peer.get_utf8_string(n)
			if buf.find("\n") >= 0:
				break
		await _frames(1)
	peer.disconnect_from_host()
	var parsed: Variant = JSON.parse_string(buf.split("\n")[0])
	if typeof(parsed) == TYPE_DICTIONARY:
		return parsed
	return {"ok": false, "error": "bad response", "raw": buf}


func _ollama_up(base_url: String) -> bool:
	var host: String = base_url.replace("http://", "").replace("https://", "")
	host = host.split("/")[0]
	var h: String = host.split(":")[0]
	var port: int = 11434
	if host.find(":") >= 0:
		port = int(host.split(":")[1])
	var peer := StreamPeerTCP.new()
	if peer.connect_to_host(h, port) != OK:
		return false
	var deadline: int = Time.get_ticks_msec() + 2000
	while peer.get_status() == StreamPeerTCP.STATUS_CONNECTING and Time.get_ticks_msec() < deadline:
		peer.poll()
		OS.delay_msec(20)
	var ok: bool = peer.get_status() == StreamPeerTCP.STATUS_CONNECTED
	peer.disconnect_from_host()
	return ok


func _extract_json_object(text: String) -> Dictionary:
	var start: int = text.find("{")
	var end: int = text.rfind("}")
	if start < 0 or end <= start:
		return {}
	var parsed: Variant = JSON.parse_string(text.substr(start, end - start + 1))
	if typeof(parsed) == TYPE_DICTIONARY:
		return parsed
	return {}


func _count_jsonl_lines(abs_path: String) -> int:
	if not FileAccess.file_exists(abs_path):
		return 0
	var text: String = FileAccess.get_file_as_string(abs_path)
	if text.strip_edges().is_empty():
		return 0
	return text.strip_edges().split("\n").size()


func _jsonl_tail(abs_path: String, n: int) -> PackedStringArray:
	if not FileAccess.file_exists(abs_path):
		return PackedStringArray()
	var lines: PackedStringArray = PackedStringArray(
		FileAccess.get_file_as_string(abs_path).strip_edges().split("\n")
	)
	if lines.size() <= n:
		return lines
	return lines.slice(lines.size() - n, lines.size())


func _shell_quote(s: String) -> String:
	return "'%s'" % s.replace("'", "'\\''")


func _shell_quote_each(parts: PackedStringArray) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for p: String in parts:
		out.append(_shell_quote(p))
	return out


func _ensure_probe_scene(path: String) -> void:
	if FileAccess.file_exists(path):
		return
	var root := Node3D.new()
	root.name = "ProbeRoot"
	var packed := PackedScene.new()
	if packed.pack(root) == OK:
		ResourceSaver.save(packed, path)
	root.free()


func _write_text(path: String, content: String) -> void:
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(content)
		f.close()


func _remove_child_named(root: Node, child_name: String) -> void:
	if root == null:
		return
	var n: Node = root.get_node_or_null(NodePath(child_name))
	if n != null:
		root.remove_child(n)
		n.free()


func _child_count(root: Node) -> int:
	return 0 if root == null else root.get_child_count()


func _undo_once(root: Node) -> bool:
	if root == null:
		return false
	var ur_mgr: EditorUndoRedoManager = EditorInterface.get_editor_undo_redo()
	var history_id: int = ur_mgr.get_object_history_id(root)
	var ur: UndoRedo = ur_mgr.get_history_undo_redo(history_id)
	if ur == null or not ur.has_undo():
		return false
	ur.undo()
	return true


func _frames(n: int) -> void:
	var tree: SceneTree = EditorInterface.get_base_control().get_tree()
	for _i: int in range(n):
		await tree.process_frame
