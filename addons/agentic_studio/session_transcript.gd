class_name AgenticStudioSessionTranscript
extends RefCounted
## Scrolling session transcript: turns under user://agentic_studio/logs/<id>.log.
## Separate from job JSON. Closing a tab does not delete this file.

# Self-preload: class_name is not visible while this script compiles.
const _Self = preload("res://addons/agentic_studio/session_transcript.gd")
const ShotSupportScript = preload("res://addons/agentic_studio/screenshot_support.gd")

const KIND_USER: String = "user"
const KIND_SYSTEM: String = "system"
const KIND_TOOL: String = "tool"
const KIND_ASSISTANT: String = "assistant"
const KIND_SCREENSHOT: String = "screenshot"

const CHEVRON_CLOSED: String = "▶"
const CHEVRON_OPEN: String = "▼"
const REMOVE_MARK: String = "[Remove]"

const STUDIO_SESSION_ID: String = "studio"

## session_id used in the log filename (no path separators).
var session_id: String = ""
var title: String = ""
## Each turn: {prompt, mode, model_id, job_id, stage, blocks:[{kind, summary, detail, collapsed}]}
var turns: Array = []
## Parallel to rendered TextEdit lines: null or {turn, block} for chevron lines.
var _line_map: Array = []


func _init(p_id: String = "") -> void:
	if p_id.is_empty():
		session_id = _make_id()
	else:
		session_id = _sanitize_id(p_id)


static func _make_id() -> String:
	return "session_%d_%d" % [Time.get_unix_time_from_system(), randi() % 100000]


static func _sanitize_id(raw: String) -> String:
	var s: String = raw.strip_edges()
	s = s.replace("/", "_").replace("\\", "_").replace("..", "_")
	if s.is_empty():
		return _make_id()
	return s


static func log_path_for(session_id: String) -> String:
	return AgenticStudioConfig.LOGS_DIR.path_join("%s.log" % _sanitize_id(session_id))


func log_path() -> String:
	return log_path_for(session_id)


static func ensure_logs_dir() -> void:
	AgenticStudioConfig.ensure_dirs()
	var abs_logs: String = ProjectSettings.globalize_path(AgenticStudioConfig.LOGS_DIR)
	if not DirAccess.dir_exists_absolute(abs_logs):
		DirAccess.make_dir_recursive_absolute(abs_logs)


func save() -> Error:
	ensure_logs_dir()
	var payload: Dictionary = {
		"session_id": session_id,
		"title": title,
		"turns": turns,
	}
	var text: String = JSON.stringify(payload, "\t")
	var path: String = log_path()
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		var err: Error = FileAccess.get_open_error()
		push_warning("AgenticStudio: could not write session log %s: error %d" % [path, err])
		return err
	file.store_string(text)
	file.close()
	return OK


static func load_from_id(p_id: String) -> AgenticStudioSessionTranscript:
	ensure_logs_dir()
	var path: String = log_path_for(p_id)
	if not FileAccess.file_exists(path):
		return null
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var text: String = file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return null
	var t = _Self.new(str((parsed as Dictionary).get("session_id", p_id)))
	t.title = str((parsed as Dictionary).get("title", ""))
	var raw_turns: Variant = (parsed as Dictionary).get("turns", [])
	if raw_turns is Array:
		t.turns = (raw_turns as Array).duplicate(true)
	return t


func begin_turn(prompt: String, mode: String, model_id: String, job_id: String) -> int:
	## Appends a new turn and returns its index.
	var turn: Dictionary = {
		"prompt": prompt,
		"mode": mode,
		"model_id": model_id,
		"job_id": job_id,
		"stage": "running",
		"blocks": [],
	}
	turns.append(turn)
	if title.is_empty():
		var snippet: String = prompt.strip_edges()
		if snippet.length() > 28:
			snippet = snippet.substr(0, 28) + "…"
		title = snippet
	return turns.size() - 1


func sync_turn_from_job(turn_index: int, job: AgenticStudioJob) -> void:
	## Rebuilds collapsible blocks from the job log while preserving collapse flags.
	if turn_index < 0 or turn_index >= turns.size():
		return
	var turn: Dictionary = turns[turn_index]
	var old_blocks: Array = turn.get("blocks", [])
	var collapse_by_key: Dictionary = {}
	for b: Variant in old_blocks:
		if typeof(b) != TYPE_DICTIONARY:
			continue
		var bd: Dictionary = b
		var key: String = "%s|%s" % [str(bd.get("kind", "")), str(bd.get("summary", ""))]
		collapse_by_key[key] = bool(bd.get("collapsed", true))

	turn["prompt"] = job.prompt
	turn["mode"] = job.mode
	turn["model_id"] = job.model_id
	turn["job_id"] = job.id
	turn["stage"] = job.stage

	var built: Array = _blocks_from_log_lines(job.log_lines)
	for i: int in range(built.size()):
		var block: Dictionary = built[i]
		var key2: String = "%s|%s" % [str(block.get("kind", "")), str(block.get("summary", ""))]
		if collapse_by_key.has(key2):
			block["collapsed"] = bool(collapse_by_key[key2])
		elif str(block.get("kind", "")) == KIND_ASSISTANT or str(block.get("kind", "")) == KIND_USER:
			block["collapsed"] = false
		else:
			block["collapsed"] = true
		built[i] = block
	turn["blocks"] = built
	turns[turn_index] = turn


static func _blocks_from_log_lines(lines: PackedStringArray) -> Array:
	var blocks: Array = []
	var pending_kind: String = ""
	var pending_summary: String = ""
	var pending_detail: PackedStringArray = PackedStringArray()

	for line: String in lines:
		var kind: String = classify_line(line)
		var summary: String = summary_for_line(kind, line)
		if kind == KIND_ASSISTANT:
			if pending_kind == KIND_ASSISTANT:
				pending_detail.append(line)
				continue
			_flush_block(blocks, pending_kind, pending_summary, pending_detail)
			pending_kind = KIND_ASSISTANT
			pending_summary = "Assistant"
			pending_detail = PackedStringArray([line])
			continue
		if pending_kind == kind and pending_summary == summary and not pending_kind.is_empty():
			pending_detail.append(line)
			continue
		_flush_block(blocks, pending_kind, pending_summary, pending_detail)
		pending_kind = kind
		pending_summary = summary
		pending_detail = PackedStringArray([line])
	_flush_block(blocks, pending_kind, pending_summary, pending_detail)
	return blocks


static func _flush_block(
	blocks: Array,
	kind: String,
	summary: String,
	detail_lines: PackedStringArray
) -> void:
	if kind.is_empty():
		return
	var detail: String = "\n".join(detail_lines)
	var block: Dictionary = {
		"kind": kind,
		"summary": summary,
		"detail": detail,
		"collapsed": kind != KIND_ASSISTANT,
	}
	if kind == KIND_SCREENSHOT:
		var shot_path: String = ""
		for dl: String in detail_lines:
			var p: String = shot_path_from_line(dl)
			if not p.is_empty():
				shot_path = p
				break
		block["shot_path"] = shot_path
	blocks.append(block)


static func classify_line(line: String) -> String:
	var t: String = line.strip_edges()
	if t.is_empty():
		return KIND_SYSTEM
	var lower: String = t.to_lower()
	if (
		lower.begins_with("job created")
		or lower.begins_with("tool round")
		or lower.begins_with("stopped after")
		or lower.begins_with("model requested")
		or lower.begins_with("plan blocked")
		or lower.begins_with("refused fifth")
		or lower.begins_with("system ready")
		or lower.begins_with("calling model")
	):
		return KIND_SYSTEM
	if lower.begins_with("screenshot"):
		return KIND_SCREENSHOT
	if lower.begins_with("skipped "):
		return KIND_TOOL
	for tool_name: String in [
		"read_scene", "add_node", "set_property", "play_scene",
		"list_pages", "get_page", "link", "create_asset",
		"list_dir", "read_file", "write_file", "delete_file",
		"check_page_drift",
	]:
		if lower.begins_with(tool_name):
			return KIND_TOOL
	# JSON-looking tool echo or blocked message.
	if lower.begins_with("blocked"):
		return KIND_SYSTEM
	return KIND_ASSISTANT


static func summary_for_line(kind: String, line: String) -> String:
	var t: String = line.strip_edges()
	if kind == KIND_SYSTEM:
		if t.to_lower().begins_with("job created"):
			return "System ready"
		if t.length() > 60:
			return t.substr(0, 57) + "…"
		return t if not t.is_empty() else "System"
	if kind == KIND_SCREENSHOT:
		# "screenshot ok target=editor_3d path=..."
		var target: String = "screenshot"
		var idx: int = t.find("target=")
		if idx >= 0:
			var rest: String = t.substr(idx + 7)
			target = rest.get_slice(" ", 0).strip_edges()
			if target.is_empty():
				target = "screenshot"
		return "Screenshot %s" % target
	if kind == KIND_TOOL:
		if t.to_lower().begins_with("skipped "):
			var rest2: String = t.substr(8).strip_edges()
			var tool: String = rest2.get_slice(" ", 0)
			return "Skipped %s" % tool
		var name: String = t.get_slice(" ", 0)
		return "Running %s" % name
	return "Assistant"


static func shot_path_from_line(line: String) -> String:
	var t: String = line.strip_edges()
	var idx: int = t.find("path=")
	if idx < 0:
		return ""
	return t.substr(idx + 5).strip_edges()


func toggle_block(turn_index: int, block_index: int) -> void:
	if turn_index < 0 or turn_index >= turns.size():
		return
	var turn: Dictionary = turns[turn_index]
	var blocks: Array = turn.get("blocks", [])
	if block_index < 0 or block_index >= blocks.size():
		return
	var block: Dictionary = blocks[block_index]
	var kind: String = str(block.get("kind", ""))
	if kind == KIND_USER or kind == KIND_ASSISTANT:
		block["collapsed"] = false
	else:
		block["collapsed"] = not bool(block.get("collapsed", true))
	blocks[block_index] = block
	turn["blocks"] = blocks
	turns[turn_index] = turn


func toggle_at_line(line_index: int) -> bool:
	## Returns true if a collapsible block was toggled.
	if line_index < 0 or line_index >= _line_map.size():
		return false
	var meta: Variant = _line_map[line_index]
	if typeof(meta) != TYPE_DICTIONARY:
		return false
	var turn_i: int = int((meta as Dictionary).get("turn", -1))
	var block_i: int = int((meta as Dictionary).get("block", -1))
	if turn_i < 0 or block_i < 0:
		return false
	var turn: Dictionary = turns[turn_i]
	var blocks: Array = turn.get("blocks", [])
	if block_i >= blocks.size():
		return false
	var kind: String = str((blocks[block_i] as Dictionary).get("kind", ""))
	if kind == KIND_ASSISTANT or kind == KIND_USER:
		return false
	toggle_block(turn_i, block_i)
	return true


func remove_shot_at_line(line_index: int) -> bool:
	## Click [Remove] on an expanded screenshot block: delete the PNG now.
	if line_index < 0 or line_index >= _line_map.size():
		return false
	var meta: Variant = _line_map[line_index]
	if typeof(meta) != TYPE_DICTIONARY:
		return false
	if not bool((meta as Dictionary).get("remove", false)):
		return false
	var turn_i: int = int((meta as Dictionary).get("turn", -1))
	var block_i: int = int((meta as Dictionary).get("block", -1))
	if turn_i < 0 or block_i < 0 or turn_i >= turns.size():
		return false
	var turn: Dictionary = turns[turn_i]
	var blocks: Array = turn.get("blocks", [])
	if block_i >= blocks.size():
		return false
	var block: Dictionary = blocks[block_i]
	if str(block.get("kind", "")) != KIND_SCREENSHOT:
		return false
	var shot_path: String = str(block.get("shot_path", ""))
	if not shot_path.is_empty():
		ShotSupportScript.delete_shot_file(shot_path)
	block["detail"] = "shot removed"
	block["shot_path"] = ""
	blocks[block_i] = block
	turn["blocks"] = blocks
	turns[turn_i] = turn
	return true


func render_text() -> String:
	## Builds the TextEdit contents and refreshes _line_map for chevron clicks.
	_line_map.clear()
	var out_lines: PackedStringArray = PackedStringArray()
	if turns.is_empty():
		out_lines.append("(empty log)")
		_line_map.append(null)
		return "\n".join(out_lines)

	for ti: int in range(turns.size()):
		var turn: Dictionary = turns[ti]
		if ti > 0:
			out_lines.append("")
			_line_map.append(null)
			out_lines.append("————")
			_line_map.append(null)
			out_lines.append("")
			_line_map.append(null)

		# User prompt — always expanded, no chevron.
		var prompt: String = str(turn.get("prompt", ""))
		out_lines.append("You")
		_line_map.append(null)
		for pl: String in prompt.split("\n"):
			out_lines.append(pl)
			_line_map.append(null)

		var mode_label: String = AgenticStudioJob.mode_label(str(turn.get("mode", "")))
		var stage: String = str(turn.get("stage", ""))
		out_lines.append("mode=%s  stage=%s" % [mode_label, stage])
		_line_map.append(null)

		var blocks: Array = turn.get("blocks", [])
		for bi: int in range(blocks.size()):
			var block: Dictionary = blocks[bi]
			var kind: String = str(block.get("kind", ""))
			var summary: String = str(block.get("summary", ""))
			var detail: String = str(block.get("detail", ""))
			var collapsed: bool = bool(block.get("collapsed", true))

			if kind == KIND_ASSISTANT:
				# Always expanded; no chevron.
				if not out_lines.is_empty() and not str(out_lines[out_lines.size() - 1]).is_empty():
					out_lines.append("")
					_line_map.append(null)
				for dl: String in detail.split("\n"):
					out_lines.append(dl)
					_line_map.append(null)
				continue

			var chevron: String = CHEVRON_CLOSED if collapsed else CHEVRON_OPEN
			out_lines.append("%s %s" % [chevron, summary])
			_line_map.append({"turn": ti, "block": bi})
			if not collapsed:
				if kind == KIND_SCREENSHOT:
					var shot_path: String = str(block.get("shot_path", ""))
					var show_detail: String = detail
					var missing: bool = shot_path.is_empty()
					if not missing:
						var abs_shot: String = ProjectSettings.globalize_path(shot_path)
						missing = not FileAccess.file_exists(abs_shot)
					if missing:
						show_detail = "shot removed"
					for dl2: String in show_detail.split("\n"):
						out_lines.append("  %s" % dl2)
						_line_map.append({"turn": ti, "block": bi})
					if not missing:
						out_lines.append("  %s" % REMOVE_MARK)
						_line_map.append({"turn": ti, "block": bi, "remove": true})
				else:
					for dl3: String in detail.split("\n"):
						out_lines.append("  %s" % dl3)
						_line_map.append({"turn": ti, "block": bi})
	return "\n".join(out_lines)


func find_turn_index_for_job(job_id: String) -> int:
	for i: int in range(turns.size()):
		if str((turns[i] as Dictionary).get("job_id", "")) == job_id:
			return i
	return -1
