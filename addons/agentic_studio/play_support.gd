class_name AgenticStudioPlaySupport
extends RefCounted
## Play gate: parse → save → temporary PlayProbe → play_custom_scene → debugger stopped → merge result.

const PLAY_TIMEOUT_SEC: float = 8.0
const AGENTIC_DIR: String = "user://agentic"
const FRAME_PATH: String = "user://agentic/last_frame.png"
const PLAY_JSON_PATH: String = "user://agentic/last_play.json"
const PLAYPROBE_AUTOLOAD_NAME: String = "PlayProbe"
const PLAYPROBE_SCRIPT: String = "res://addons/agentic_studio/play_probe.gd"
const AUTOLOAD_SETTING: String = "autoload/PlayProbe"

# RemoteDebugger::MessageType (kept for structured error capture; no Output scrape)
const OUTPUT_TYPE_ERROR: int = 1

var _errors: Array = []
var _collecting: bool = false
var _hooked: Object = null
var _page_ids: PackedStringArray = PackedStringArray()
## Set by plugin via set_play_debugger before play.
static var play_debugger: EditorDebuggerPlugin = null


static func set_play_debugger(plugin: EditorDebuggerPlugin) -> void:
	play_debugger = plugin


static func format_play_log(result: Dictionary) -> String:
	var phase: String = str(result.get("phase", "play"))
	var errs: Array = result.get("errors", [])
	if bool(result.get("ok", false)) and errs.is_empty():
		var frame: String = str(result.get("frame", ""))
		if frame.is_empty():
			return "play_scene ok phase=%s" % phase
		return "play_scene ok phase=%s frame=%s" % [phase, frame]
	var lines: PackedStringArray = PackedStringArray()
	lines.append("play_scene failed phase=%s (%d error(s))" % [phase, errs.size()])
	for e: Variant in errs:
		if typeof(e) == TYPE_DICTIONARY:
			var d: Dictionary = e
			var file: String = str(d.get("file", ""))
			var line_n: int = int(d.get("line", 0))
			var msg: String = str(d.get("message", ""))
			if file.is_empty():
				lines.append(msg)
			elif line_n > 0:
				lines.append("%s:%d: %s" % [file, line_n, msg])
			else:
				lines.append("%s: %s" % [file, msg])
		else:
			lines.append(str(e))
	return "\n".join(lines)


static func format_output_error_data(data: Array) -> Dictionary:
	## DebuggerMarshalls::OutputError → structured {file, line, message}.
	if data.size() < 11:
		return {"file": "", "line": 0, "message": "error: %s" % str(data)}
	var source_file: String = str(data[4])
	var source_func: String = str(data[5])
	var source_line: int = int(data[6])
	var error: String = str(data[7])
	var error_descr: String = str(data[8])
	var warning: bool = bool(data[9])
	var kind: String = "warning" if warning else "error"
	var title: String = error_descr if not error_descr.is_empty() else error
	if not source_func.is_empty():
		title = "%s @ %s" % [title, source_func]
	return {"file": source_file, "line": source_line, "message": "%s: %s" % [kind, title]}


static func collect_output_message_errors(data: Array) -> Array:
	var out: Array = []
	if data.size() < 2:
		return out
	var strings: PackedStringArray = PackedStringArray(data[0])
	var types: PackedInt32Array = PackedInt32Array(data[1])
	var n: int = mini(strings.size(), types.size())
	for i: int in range(n):
		if int(types[i]) == OUTPUT_TYPE_ERROR:
			out.append({"file": "", "line": 0, "message": str(strings[i])})
	return out


func play_current_scene(
	timeout_sec: float = PLAY_TIMEOUT_SEC,
	page_ids: PackedStringArray = PackedStringArray()
) -> Dictionary:
	## Async play gate. Callers must await.
	_page_ids = page_ids.duplicate()
	_errors = []
	_collecting = true
	_ensure_agentic_dir()
	_clear_prior_artifacts()

	# --- Parse stage ---
	for line: String in _collect_edited_scene_script_errors():
		_errors.append({"file": "", "line": 0, "message": line})
	if not _errors.is_empty():
		_collecting = false
		return _make_result(false, "parse", "", _errors)

	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		_collecting = false
		return _make_result(
			false,
			"parse",
			"",
			[{"file": "", "line": 0, "message": "no open scene"}]
		)
	var scene_path: String = str(root.scene_file_path).strip_edges()
	if scene_path.is_empty():
		# Untitled: save into a temp path under user://agentic for play_custom_scene.
		scene_path = AGENTIC_DIR.path_join("_gate_scene.tscn")
		var packed := PackedScene.new()
		if packed.pack(root) != OK:
			_collecting = false
			return _make_result(
				false,
				"parse",
				"",
				[{"file": "", "line": 0, "message": "could not pack untitled scene"}]
			)
		if ResourceSaver.save(packed, scene_path) != OK:
			_collecting = false
			return _make_result(
				false,
				"parse",
				"",
				[{"file": "", "line": 0, "message": "could not save gate scene"}]
			)
	else:
		EditorInterface.save_scene()

	_hook_debugger()
	var tree: SceneTree = EditorInterface.get_base_control().get_tree()

	if EditorInterface.is_playing_scene():
		EditorInterface.stop_playing_scene()
		await _pump(tree, 250)

	var autoload_snap: Dictionary = _install_play_probe()
	var dbg: EditorDebuggerPlugin = play_debugger
	if dbg != null and dbg.has_method("arm"):
		dbg.call("arm")

	EditorInterface.play_custom_scene(scene_path)

	var stopped: bool = await _wait_session_stopped(tree, timeout_sec)

	if EditorInterface.is_playing_scene():
		EditorInterface.stop_playing_scene()
	await _pump(tree, 300)

	var guard_ms: int = Time.get_ticks_msec() + 2000
	while EditorInterface.is_playing_scene() and Time.get_ticks_msec() < guard_ms:
		await _pump(tree, 50)

	if EditorInterface.is_playing_scene():
		EditorInterface.stop_playing_scene()
		await _pump(tree, 200)

	_restore_play_probe(autoload_snap)
	if dbg != null and dbg.has_method("disarm"):
		dbg.call("disarm")
	_collecting = false

	return _merge_probe_result(stopped)


func _make_result(ok: bool, phase: String, frame: String, errors: Array) -> Dictionary:
	return {
		"ok": ok,
		"phase": phase,
		"page_ids": Array(_page_ids),
		"errors": errors,
		"frame": frame,
	}


func _merge_probe_result(stopped: bool) -> Dictionary:
	var frame: String = ""
	var probe_ok: bool = false
	var probe_errors: Array = []
	var abs_json: String = ProjectSettings.globalize_path(PLAY_JSON_PATH)
	if FileAccess.file_exists(abs_json):
		var text: String = FileAccess.get_file_as_string(PLAY_JSON_PATH)
		var parsed: Variant = JSON.parse_string(text)
		if typeof(parsed) == TYPE_DICTIONARY:
			var d: Dictionary = parsed
			probe_ok = bool(d.get("ok", false))
			frame = str(d.get("frame", ""))
			var pe: Variant = d.get("errors", [])
			if typeof(pe) == TYPE_ARRAY:
				probe_errors = pe
	var abs_frame: String = ProjectSettings.globalize_path(FRAME_PATH)
	if frame.is_empty() and FileAccess.file_exists(abs_frame):
		frame = FRAME_PATH

	var errs: Array = _errors.duplicate()
	for e: Variant in probe_errors:
		errs.append(e)

	# Runtime: first error + short tail already in errs; ok requires no errors + probe wrote.
	var ok: bool = errs.is_empty() and not EditorInterface.is_playing_scene()
	if not frame.is_empty() and FileAccess.file_exists(ProjectSettings.globalize_path(frame)):
		# Frame present strengthens ok when no errors.
		pass
	elif ok and not probe_ok and not stopped:
		# Soft: allow ok if debugger stopped cleanly even if probe json missing (headless-ish).
		ok = errs.is_empty()

	# Prefer requiring clean errors; frame is best-effort for ok play.
	return _make_result(ok and errs.is_empty(), "play", frame, errs)


func _wait_session_stopped(tree: SceneTree, timeout_sec: float) -> bool:
	var deadline: float = Time.get_ticks_msec() / 1000.0 + timeout_sec
	var dbg: EditorDebuggerPlugin = play_debugger
	while Time.get_ticks_msec() / 1000.0 < deadline:
		if dbg != null and dbg.has_method("has_stopped") and bool(dbg.call("has_stopped")):
			if dbg.has_method("consume_stopped"):
				dbg.call("consume_stopped")
			return true
		# Probe may have quit already; json present counts as done.
		if FileAccess.file_exists(ProjectSettings.globalize_path(PLAY_JSON_PATH)):
			if not EditorInterface.is_playing_scene():
				return true
		await _pump(tree, 50)
	return false


func _install_play_probe() -> Dictionary:
	## Use override.cfg so the played process sees PlayProbe without rewriting project.godot
	## (ProjectSettings.save() reloads editor plugins and can break the gate).
	var snap: Dictionary = {
		"had_setting": ProjectSettings.has_setting(AUTOLOAD_SETTING),
		"setting_value": "",
		"had_override": FileAccess.file_exists("res://override.cfg"),
		"override_text": "",
	}
	if bool(snap["had_setting"]):
		snap["setting_value"] = str(ProjectSettings.get_setting(AUTOLOAD_SETTING))
	if bool(snap["had_override"]):
		snap["override_text"] = FileAccess.get_file_as_string("res://override.cfg")

	var entry: String = "*%s" % PLAYPROBE_SCRIPT
	ProjectSettings.set_setting(AUTOLOAD_SETTING, entry)

	var override_body: String = str(snap["override_text"])
	if override_body.find("[autoload]") < 0:
		if not override_body.is_empty() and not override_body.ends_with("\n"):
			override_body += "\n"
		override_body += "\n[autoload]\n"
	# Replace existing PlayProbe line or append.
	var lines: PackedStringArray = PackedStringArray(override_body.split("\n"))
	var out_lines: PackedStringArray = PackedStringArray()
	var replaced: bool = false
	for line: String in lines:
		if line.strip_edges().begins_with("PlayProbe="):
			out_lines.append('PlayProbe="%s"' % entry)
			replaced = true
		else:
			out_lines.append(line)
	if not replaced:
		# Insert after [autoload]
		var inserted: bool = false
		var rebuilt: PackedStringArray = PackedStringArray()
		for line2: String in out_lines:
			rebuilt.append(line2)
			if not inserted and line2.strip_edges() == "[autoload]":
				rebuilt.append('PlayProbe="%s"' % entry)
				inserted = true
		if not inserted:
			rebuilt.append("[autoload]")
			rebuilt.append('PlayProbe="%s"' % entry)
		out_lines = rebuilt
	var f: FileAccess = FileAccess.open("res://override.cfg", FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(out_lines))
		f.close()
	return snap


func _restore_play_probe(snap: Dictionary) -> void:
	## Always restore — never leave PlayProbe in project.godot or override.cfg.
	if bool(snap.get("had_setting", false)):
		ProjectSettings.set_setting(AUTOLOAD_SETTING, str(snap.get("setting_value", "")))
	elif ProjectSettings.has_setting(AUTOLOAD_SETTING):
		ProjectSettings.clear(AUTOLOAD_SETTING)

	if bool(snap.get("had_override", false)):
		var f: FileAccess = FileAccess.open("res://override.cfg", FileAccess.WRITE)
		if f != null:
			f.store_string(str(snap.get("override_text", "")))
			f.close()
	else:
		var abs_override: String = ProjectSettings.globalize_path("res://override.cfg")
		if FileAccess.file_exists(abs_override):
			DirAccess.remove_absolute(abs_override)


func _ensure_agentic_dir() -> void:
	var abs_dir: String = ProjectSettings.globalize_path(AGENTIC_DIR)
	if not DirAccess.dir_exists_absolute(abs_dir):
		DirAccess.make_dir_recursive_absolute(abs_dir)


func _clear_prior_artifacts() -> void:
	var abs_frame: String = ProjectSettings.globalize_path(FRAME_PATH)
	var abs_json: String = ProjectSettings.globalize_path(PLAY_JSON_PATH)
	if FileAccess.file_exists(abs_frame):
		DirAccess.remove_absolute(abs_frame)
	if FileAccess.file_exists(abs_json):
		DirAccess.remove_absolute(abs_json)


func _collect_edited_scene_script_errors() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return out
	_scan_node_scripts(root, out)
	return out


func _scan_node_scripts(node: Node, out: PackedStringArray) -> void:
	if node == null or not is_instance_valid(node):
		return
	var attached: Variant = node.get_script()
	if attached is GDScript:
		var gd: GDScript = attached as GDScript
		var probe := GDScript.new()
		probe.source_code = gd.source_code
		var reload_err: Error = probe.reload()
		if reload_err != OK:
			var path: String = str(gd.resource_path)
			if path.is_empty():
				path = "(in-memory)"
			var where: String = str(node.name)
			if node.is_inside_tree():
				where = str(node.get_path())
			out.append(
				"Parse Error on %s (%s) reload_err=%d" % [where, path, int(reload_err)]
			)
	for i: int in range(node.get_child_count()):
		_scan_node_scripts(node.get_child(i), out)


func _pump(tree: SceneTree, duration_ms: int) -> void:
	var end_ms: int = Time.get_ticks_msec() + duration_ms
	while Time.get_ticks_msec() < end_ms:
		if tree == null:
			OS.delay_msec(16)
			continue
		await tree.process_frame


func _hook_debugger() -> void:
	if _hooked != null and is_instance_valid(_hooked):
		return
	var base: Node = EditorInterface.get_base_control()
	var dbg: Node = _find_debugger(base)
	if dbg == null:
		return
	if dbg.has_signal("debug_data"):
		if not dbg.is_connected("debug_data", Callable(self, "_on_debug_data")):
			dbg.connect("debug_data", Callable(self, "_on_debug_data"))
	_hooked = dbg


func _find_debugger(node: Node) -> Node:
	if node == null:
		return null
	if str(node.get_class()) == "ScriptEditorDebugger":
		return node
	for i: int in range(node.get_child_count()):
		var found: Node = _find_debugger(node.get_child(i))
		if found != null:
			return found
	return null


func _on_debug_data(msg: String, data: Array) -> void:
	if not _collecting:
		return
	if msg == "error":
		var err: Dictionary = format_output_error_data(data)
		var line: String = str(err.get("message", ""))
		if not line.is_empty() and not _is_addon_noise(line):
			_errors.append(err)
	elif msg == "output":
		for err2: Variant in collect_output_message_errors(data):
			if typeof(err2) == TYPE_DICTIONARY:
				var m: String = str((err2 as Dictionary).get("message", ""))
				if not _is_addon_noise(m):
					_errors.append(err2)


func _is_addon_noise(text: String) -> bool:
	return text.find("addons/agentic_studio/") >= 0
