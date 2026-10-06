class_name AgenticStudioSessionLog
extends RefCounted
## Append one JSON line per plan or run under res://.agentic/sessions/.
## Records model id, role, and display name. Never the API key or a secret-bearing URL.

const ROOT: String = "res://.agentic"
const SESSIONS_DIR: String = "res://.agentic/sessions"


static func ensure_dirs() -> void:
	_ensure_dir(ROOT)
	_ensure_dir(SESSIONS_DIR)


static func _ensure_dir(path: String) -> void:
	var abs_path: String = ProjectSettings.globalize_path(path)
	if DirAccess.dir_exists_absolute(abs_path):
		return
	DirAccess.make_dir_recursive_absolute(abs_path)


static func path_for_day(day: String = "") -> String:
	ensure_dirs()
	var d: String = day
	if d.is_empty():
		var dt: Dictionary = Time.get_datetime_dict_from_system()
		d = "%04d-%02d-%02d" % [int(dt.get("year", 1970)), int(dt.get("month", 1)), int(dt.get("day", 1))]
	return SESSIONS_DIR.path_join("%s.jsonl" % d)


static func append_entry(entry: Dictionary) -> void:
	ensure_dirs()
	var path: String = path_for_day()
	var abs_path: String = ProjectSettings.globalize_path(path)
	var prior: String = ""
	if FileAccess.file_exists(abs_path):
		prior = FileAccess.get_file_as_string(abs_path)
	var line: String = JSON.stringify(entry)
	var f: FileAccess = FileAccess.open(abs_path, FileAccess.WRITE)
	if f == null:
		push_warning("AgenticStudio: could not write session log %s" % path)
		return
	if not prior.is_empty():
		f.store_string(prior)
		if not prior.ends_with("\n"):
			f.store_string("\n")
	f.store_string(line)
	f.store_string("\n")
	f.close()


static func read_recent_lines(max_lines: int = 40) -> PackedStringArray:
	var path: String = path_for_day()
	var abs_path: String = ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(abs_path):
		return PackedStringArray()
	var text: String = FileAccess.get_file_as_string(abs_path).strip_edges()
	if text.is_empty():
		return PackedStringArray()
	var lines: PackedStringArray = PackedStringArray(text.split("\n"))
	if lines.size() <= max_lines:
		return lines
	return lines.slice(lines.size() - max_lines, lines.size())


static func append_plan_or_run(
	model_id: String,
	mode: String,
	page_ids: PackedStringArray,
	ops: Array,
	play_result: Variant,
	model: Dictionary = {}
) -> void:
	var fields: Dictionary = {}
	if not model.is_empty():
		fields = AgenticStudioConfig.model_log_fields(model)
	else:
		var loaded: Dictionary = AgenticStudioConfig.get_model(model_id)
		if not loaded.is_empty():
			fields = AgenticStudioConfig.model_log_fields(loaded)
		else:
			fields = {
				"model_id": model_id,
				"role": "",
				"display_name": "",
			}
	var entry: Dictionary = {
		"ts": Time.get_unix_time_from_system(),
		"model_id": str(fields.get("model_id", model_id)),
		"role": str(fields.get("role", "")),
		"display_name": str(fields.get("display_name", "")),
		"mode": mode,
		"page_ids": Array(page_ids),
		"ops": ops,
		"play": play_result,
	}
	append_entry(entry)
