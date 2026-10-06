class_name AgenticStudioJob
extends RefCounted
## One agent job, persisted as JSON under user://agentic_studio/jobs/.

const MODE_PLAN: String = "plan"
const MODE_RUN: String = "run"
const MODE_AUTO_APPROVE: String = "auto_approve"

const CHANNEL_STUDIO: String = "studio"
const CHANNEL_SESSION: String = "session"

const STAGE_IDLE: String = "idle"
const STAGE_RUNNING: String = "running"
const STAGE_PLANNED: String = "planned"
const STAGE_DONE: String = "done"
const STAGE_FAILED: String = "failed"
const STAGE_ERROR: String = "error"

var id: String = ""
var prompt: String = ""
var model_id: String = ""
var mode: String = MODE_PLAN
var channel: String = CHANNEL_SESSION
var stage: String = STAGE_IDLE
var log_lines: PackedStringArray = PackedStringArray()
var created_at: int = 0
var updated_at: int = 0


func _init(p_id: String = "") -> void:
	if p_id.is_empty():
		id = _make_id()
	else:
		id = p_id
	var now: int = int(Time.get_unix_time_from_system())
	created_at = now
	updated_at = now


static func _make_id() -> String:
	return "job_%d_%d" % [Time.get_unix_time_from_system(), randi() % 100000]


func file_path() -> String:
	return AgenticStudioConfig.JOBS_DIR.path_join("%s.json" % id)


func tab_title() -> String:
	var snippet: String = prompt.strip_edges()
	if snippet.is_empty():
		return ""
	elif snippet.length() > 28:
		snippet = snippet.substr(0, 28) + "…"
	return snippet


func append_log(line: String) -> void:
	log_lines.append(line)
	updated_at = int(Time.get_unix_time_from_system())


func to_dictionary() -> Dictionary:
	return {
		"id": id,
		"prompt": prompt,
		"model_id": model_id,
		"mode": mode,
		"channel": channel,
		"stage": stage,
		"log": Array(log_lines),
		"created_at": created_at,
		"updated_at": updated_at,
	}


func apply_dictionary(data: Dictionary) -> void:
	id = str(data.get("id", id))
	prompt = str(data.get("prompt", ""))
	model_id = str(data.get("model_id", ""))
	mode = str(data.get("mode", MODE_PLAN))
	channel = str(data.get("channel", CHANNEL_SESSION))
	if channel != CHANNEL_STUDIO and channel != CHANNEL_SESSION:
		channel = CHANNEL_SESSION
	stage = str(data.get("stage", STAGE_IDLE))
	created_at = int(data.get("created_at", 0))
	updated_at = int(data.get("updated_at", 0))
	log_lines = PackedStringArray()
	var raw_log: Variant = data.get("log", [])
	if raw_log is Array:
		for item: Variant in raw_log:
			log_lines.append(str(item))


func save() -> Error:
	AgenticStudioConfig.ensure_dirs()
	updated_at = int(Time.get_unix_time_from_system())
	var json_text: String = JSON.stringify(to_dictionary(), "\t")
	var path: String = file_path()
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		var err: Error = FileAccess.get_open_error()
		push_warning("AgenticStudio: could not write job %s: error %d" % [path, err])
		return err
	file.store_string(json_text)
	file.close()
	return OK


static func load_from_path(path: String) -> AgenticStudioJob:
	if not FileAccess.file_exists(path):
		return null
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("AgenticStudio: could not read job %s" % path)
		return null
	var text: String = file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("AgenticStudio: invalid job JSON at %s" % path)
		return null
	var job := AgenticStudioJob.new()
	job.apply_dictionary(parsed)
	return job


static func load_all() -> Array[AgenticStudioJob]:
	AgenticStudioConfig.ensure_dirs()
	var jobs: Array[AgenticStudioJob] = []
	var abs_dir: String = ProjectSettings.globalize_path(AgenticStudioConfig.JOBS_DIR)
	var dir: DirAccess = DirAccess.open(abs_dir)
	if dir == null:
		return jobs
	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".json"):
			var job: AgenticStudioJob = load_from_path(AgenticStudioConfig.JOBS_DIR.path_join(file_name))
			if job != null:
				jobs.append(job)
		file_name = dir.get_next()
	dir.list_dir_end()
	jobs.sort_custom(func(a: AgenticStudioJob, b: AgenticStudioJob) -> bool:
		return a.created_at < b.created_at
	)
	return jobs


static func mode_label(mode_value: String) -> String:
	match mode_value:
		MODE_PLAN:
			return "Plan"
		MODE_RUN:
			return "Run"
		MODE_AUTO_APPROVE:
			return "Auto-approve"
		_:
			return mode_value


static func mode_from_index(index: int) -> String:
	match index:
		0:
			return MODE_PLAN
		1:
			return MODE_RUN
		2:
			return MODE_AUTO_APPROVE
		_:
			return MODE_PLAN


static func index_from_mode(mode_value: String) -> int:
	match mode_value:
		MODE_PLAN:
			return 0
		MODE_RUN:
			return 1
		MODE_AUTO_APPROVE:
			return 2
		_:
			return 0
