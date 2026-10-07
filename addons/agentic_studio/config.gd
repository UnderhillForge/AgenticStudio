class_name AgenticStudioConfig
extends RefCounted
## Settings for AgenticStudio. Lives in user://agentic_studio.cfg — never in git.
## API keys stay in that file only. Never write a key to the repo, fixtures, logs, or session jsonl.

const CONFIG_PATH: String = "user://agentic_studio.cfg"
const JOBS_DIR: String = "user://agentic_studio/jobs/"
const LOGS_DIR: String = "user://agentic_studio/logs/"

const SECTION_GENERAL: String = "general"
const SECTION_TOOLS: String = "tools"
const SECTION_MODELS: String = "models"
const SECTION_EXTRA_TOOLS: String = "extra_tools"
const SECTION_SESSIONS: String = "sessions"

const KEY_SELECTED_MODEL: String = "selected_model_id" # legacy alias → coder
const KEY_SELECTED_PLANNER: String = "selected_planner_id"
const KEY_SELECTED_CODER: String = "selected_coder_id"
const KEY_BLENDER_PATH: String = "blender_path"
const KEY_DRAWTHINGS_CLI: String = "drawthings_cli"
const KEY_DRAWTHINGS_MODELS_DIR: String = "drawthings_models_dir"
const KEY_DRAWTHINGS_MODEL: String = "drawthings_model"
const KEY_MODEL_IDS: String = "ids"
const KEY_EXTRA_IDS: String = "ids"
const KEY_OPEN_SESSION_IDS: String = "open_ids"

const ROLE_PLANNER: String = "planner"
const ROLE_CODER: String = "coder"

const KIND_LOCAL: String = "local"
const KIND_EXTERNAL: String = "external"

const PROVIDER_GROK: String = "grok"
const PROVIDER_GROK_BUILD: String = "grok_build"
const PROVIDER_OLLAMA: String = "ollama"

const GROK_BASE_URL: String = "https://api.x.ai/v1"
const GROK_MODEL_NAME: String = "grok-4.7"
const DEFAULT_OLLAMA_BASE: String = "http://192.168.68.55:11434/v1"

const DEFAULT_CODER_CONTEXT: int = 8192
const DEFAULT_PLANNER_CONTEXT: int = 32768

const STABLE_GROK_ID: String = "provider_grok"


static func ensure_dirs() -> void:
	var abs_jobs: String = ProjectSettings.globalize_path(JOBS_DIR)
	if not DirAccess.dir_exists_absolute(abs_jobs):
		DirAccess.make_dir_recursive_absolute(abs_jobs)
	var abs_logs: String = ProjectSettings.globalize_path(LOGS_DIR)
	if not DirAccess.dir_exists_absolute(abs_logs):
		DirAccess.make_dir_recursive_absolute(abs_logs)


static func load_config() -> ConfigFile:
	ensure_dirs()
	var cfg := ConfigFile.new()
	var err: Error = cfg.load(CONFIG_PATH)
	if err != OK and err != ERR_FILE_NOT_FOUND:
		push_warning("AgenticStudio: could not load config (%s): error %d" % [CONFIG_PATH, err])
	return cfg


static func save_config(cfg: ConfigFile) -> Error:
	ensure_dirs()
	var err: Error = cfg.save(CONFIG_PATH)
	if err != OK:
		push_warning("AgenticStudio: could not save config (%s): error %d" % [CONFIG_PATH, err])
	return err


static func make_model_id() -> String:
	return "model_%d_%d" % [Time.get_unix_time_from_system(), randi() % 100000]


static func make_extra_tool_id() -> String:
	return "tool_%d_%d" % [Time.get_unix_time_from_system(), randi() % 100000]


static func normalize_role(role: String) -> String:
	var r: String = role.strip_edges().to_lower()
	if r == ROLE_PLANNER:
		return ROLE_PLANNER
	return ROLE_CODER


static func default_context_length(role: String) -> int:
	if normalize_role(role) == ROLE_PLANNER:
		return DEFAULT_PLANNER_CONTEXT
	return DEFAULT_CODER_CONTEXT


## Legacy single selection maps to the coder.
static func get_selected_model_id(cfg: ConfigFile = null) -> String:
	return get_selected_coder_id(cfg)


static func set_selected_model_id(model_id: String, cfg: ConfigFile = null) -> void:
	set_selected_coder_id(model_id, cfg)


static func get_selected_planner_id(cfg: ConfigFile = null) -> String:
	var c: ConfigFile = cfg if cfg != null else load_config()
	return str(c.get_value(SECTION_GENERAL, KEY_SELECTED_PLANNER, ""))


static func set_selected_planner_id(model_id: String, cfg: ConfigFile = null) -> void:
	var c: ConfigFile = cfg if cfg != null else load_config()
	c.set_value(SECTION_GENERAL, KEY_SELECTED_PLANNER, model_id)
	save_config(c)


static func get_selected_coder_id(cfg: ConfigFile = null) -> String:
	var c: ConfigFile = cfg if cfg != null else load_config()
	var coder: String = str(c.get_value(SECTION_GENERAL, KEY_SELECTED_CODER, ""))
	if not coder.is_empty():
		return coder
	# Migrate legacy selected_model_id.
	return str(c.get_value(SECTION_GENERAL, KEY_SELECTED_MODEL, ""))


static func set_selected_coder_id(model_id: String, cfg: ConfigFile = null) -> void:
	var c: ConfigFile = cfg if cfg != null else load_config()
	c.set_value(SECTION_GENERAL, KEY_SELECTED_CODER, model_id)
	c.set_value(SECTION_GENERAL, KEY_SELECTED_MODEL, model_id)
	save_config(c)


static func get_blender_path(cfg: ConfigFile = null) -> String:
	var c: ConfigFile = cfg if cfg != null else load_config()
	return str(c.get_value(SECTION_TOOLS, KEY_BLENDER_PATH, ""))


static func set_blender_path(path: String, cfg: ConfigFile = null) -> void:
	var c: ConfigFile = cfg if cfg != null else load_config()
	c.set_value(SECTION_TOOLS, KEY_BLENDER_PATH, path)
	save_config(c)


static func get_drawthings_cli(cfg: ConfigFile = null) -> String:
	var c: ConfigFile = cfg if cfg != null else load_config()
	return str(c.get_value(SECTION_TOOLS, KEY_DRAWTHINGS_CLI, ""))


static func set_drawthings_cli(path: String, cfg: ConfigFile = null) -> void:
	var c: ConfigFile = cfg if cfg != null else load_config()
	c.set_value(SECTION_TOOLS, KEY_DRAWTHINGS_CLI, path)
	save_config(c)


static func get_drawthings_models_dir(cfg: ConfigFile = null) -> String:
	var c: ConfigFile = cfg if cfg != null else load_config()
	return str(c.get_value(SECTION_TOOLS, KEY_DRAWTHINGS_MODELS_DIR, ""))


static func set_drawthings_models_dir(path: String, cfg: ConfigFile = null) -> void:
	var c: ConfigFile = cfg if cfg != null else load_config()
	c.set_value(SECTION_TOOLS, KEY_DRAWTHINGS_MODELS_DIR, path)
	save_config(c)


static func get_drawthings_model(cfg: ConfigFile = null) -> String:
	var c: ConfigFile = cfg if cfg != null else load_config()
	return str(c.get_value(SECTION_TOOLS, KEY_DRAWTHINGS_MODEL, ""))


static func set_drawthings_model(filename: String, cfg: ConfigFile = null) -> void:
	var c: ConfigFile = cfg if cfg != null else load_config()
	c.set_value(SECTION_TOOLS, KEY_DRAWTHINGS_MODEL, filename)
	save_config(c)


static func list_models(cfg: ConfigFile = null) -> Array[Dictionary]:
	var c: ConfigFile = cfg if cfg != null else load_config()
	var ids: PackedStringArray = PackedStringArray(c.get_value(SECTION_MODELS, KEY_MODEL_IDS, PackedStringArray()))
	var out: Array[Dictionary] = []
	for id: String in ids:
		var section: String = _model_section(id)
		if not c.has_section(section):
			continue
		out.append(_read_model(c, id))
	return out


static func list_models_for_role(role: String, cfg: ConfigFile = null) -> Array[Dictionary]:
	var want: String = normalize_role(role)
	var out: Array[Dictionary] = []
	for m: Dictionary in list_models(cfg):
		if normalize_role(str(m.get("role", ROLE_CODER))) == want:
			out.append(m)
	return out


static func get_model(model_id: String, cfg: ConfigFile = null) -> Dictionary:
	var c: ConfigFile = cfg if cfg != null else load_config()
	if model_id.is_empty() or not c.has_section(_model_section(model_id)):
		return {}
	return _read_model(c, model_id)


static func get_selected_planner(cfg: ConfigFile = null) -> Dictionary:
	return get_model(get_selected_planner_id(cfg), cfg)


static func get_selected_coder(cfg: ConfigFile = null) -> Dictionary:
	return get_model(get_selected_coder_id(cfg), cfg)


static func upsert_model(model: Dictionary, cfg: ConfigFile = null) -> String:
	var c: ConfigFile = cfg if cfg != null else load_config()
	var id: String = str(model.get("id", ""))
	if id.is_empty():
		id = make_model_id()
		model["id"] = id

	var ids: PackedStringArray = PackedStringArray(c.get_value(SECTION_MODELS, KEY_MODEL_IDS, PackedStringArray()))
	if not ids.has(id):
		ids.append(id)
		c.set_value(SECTION_MODELS, KEY_MODEL_IDS, ids)

	var role: String = normalize_role(str(model.get("role", ROLE_CODER)))
	var kind: String = str(model.get("kind", KIND_LOCAL))
	var ctx: int = int(model.get("context_length", 0))
	if ctx <= 0:
		ctx = default_context_length(role)

	var section: String = _model_section(id)
	c.set_value(section, "display_name", str(model.get("display_name", id)))
	c.set_value(section, "kind", kind)
	c.set_value(section, "role", role)
	c.set_value(section, "base_url", str(model.get("base_url", "")))
	c.set_value(section, "model_name", str(model.get("model_name", "")))
	c.set_value(section, "context_length", ctx)
	c.set_value(section, "accepts_images", bool(model.get("accepts_images", false)))
	c.set_value(section, "provider", str(model.get("provider", "")))
	# API key only for external models; stored in user:// config, never in the repo.
	if kind == KIND_EXTERNAL:
		c.set_value(section, "api_key", str(model.get("api_key", "")))
	elif c.has_section_key(section, "api_key"):
		c.erase_section_key(section, "api_key")

	save_config(c)
	return id


## Upsert the single cloud Grok planner row (stable id).
static func upsert_grok_planner(api_key: String = "", cfg: ConfigFile = null) -> String:
	var c: ConfigFile = cfg if cfg != null else load_config()
	var existing: Dictionary = get_model(STABLE_GROK_ID, c)
	var key: String = api_key
	if key.is_empty() and not existing.is_empty():
		key = str(existing.get("api_key", ""))
	var ctx: int = int(existing.get("context_length", 0)) if not existing.is_empty() else DEFAULT_PLANNER_CONTEXT
	if ctx <= 0:
		ctx = DEFAULT_PLANNER_CONTEXT
	return upsert_model({
		"id": STABLE_GROK_ID,
		"display_name": "Grok",
		"kind": KIND_EXTERNAL,
		"role": ROLE_PLANNER,
		"provider": PROVIDER_GROK,
		"base_url": GROK_BASE_URL,
		"model_name": GROK_MODEL_NAME,
		"context_length": ctx,
		"api_key": key,
	}, c)


## Add a local Grok Build planner row (blank base_url until the user sets it).
## Two rows (Mini + debian.local) are the expected case — always creates a new id.
static func add_grok_build_planner(display_name: String = "Grok Build", cfg: ConfigFile = null) -> String:
	var name: String = display_name.strip_edges()
	if name.is_empty():
		name = "Grok Build"
	return upsert_model({
		"id": "",
		"display_name": name,
		"kind": KIND_LOCAL,
		"role": ROLE_PLANNER,
		"provider": PROVIDER_GROK_BUILD,
		"base_url": "",
		"model_name": "grok-build",
		"context_length": DEFAULT_PLANNER_CONTEXT,
	}, cfg)


## Local Ollama coder defaults. Upserts by id when provided; otherwise creates.
static func upsert_ollama_coder(
	display_name: String = "Local Coder",
	base_url: String = DEFAULT_OLLAMA_BASE,
	model_name: String = "qwen2.5-coder:7b",
	model_id: String = "",
	cfg: ConfigFile = null
) -> String:
	return upsert_model({
		"id": model_id,
		"display_name": display_name,
		"kind": KIND_LOCAL,
		"role": ROLE_CODER,
		"provider": PROVIDER_OLLAMA,
		"base_url": base_url,
		"model_name": model_name,
		"context_length": DEFAULT_CODER_CONTEXT,
	}, cfg)


static func remove_model(model_id: String, cfg: ConfigFile = null) -> void:
	var c: ConfigFile = cfg if cfg != null else load_config()
	var ids: PackedStringArray = PackedStringArray(c.get_value(SECTION_MODELS, KEY_MODEL_IDS, PackedStringArray()))
	var next: PackedStringArray = PackedStringArray()
	for id: String in ids:
		if id != model_id:
			next.append(id)
	c.set_value(SECTION_MODELS, KEY_MODEL_IDS, next)
	var section: String = _model_section(model_id)
	if c.has_section(section):
		c.erase_section(section)
	if get_selected_coder_id(c) == model_id:
		c.set_value(SECTION_GENERAL, KEY_SELECTED_CODER, "")
		c.set_value(SECTION_GENERAL, KEY_SELECTED_MODEL, "")
	if get_selected_planner_id(c) == model_id:
		c.set_value(SECTION_GENERAL, KEY_SELECTED_PLANNER, "")
	save_config(c)


## Validate a model row for HTTP. Named errors; no role fallback.
static func validate_role_endpoint(model: Dictionary, expected_role: String = "") -> Dictionary:
	var display: String = str(model.get("display_name", model.get("id", "model")))
	if model.is_empty():
		var role_label: String = expected_role if not expected_role.is_empty() else "model"
		return {"ok": false, "error": "No %s selected" % role_label}
	var role: String = normalize_role(str(model.get("role", ROLE_CODER)))
	if not expected_role.is_empty() and role != normalize_role(expected_role):
		return {
			"ok": false,
			"error": "%s has role=%s, expected %s" % [display, role, expected_role],
		}
	var base_url: String = str(model.get("base_url", "")).strip_edges()
	if base_url.is_empty():
		var provider: String = str(model.get("provider", ""))
		if provider == PROVIDER_GROK_BUILD or role == ROLE_PLANNER:
			return {
				"ok": false,
				"error": "Build URL missing for %s — set base_url in Settings" % display,
			}
		return {"ok": false, "error": "Base URL missing for %s" % display}
	var model_name: String = str(model.get("model_name", "")).strip_edges()
	if model_name.is_empty():
		return {"ok": false, "error": "Model name missing for %s" % display}
	var kind: String = str(model.get("kind", KIND_LOCAL))
	if kind == KIND_EXTERNAL:
		var key: String = str(model.get("api_key", "")).strip_edges()
		if key.is_empty():
			return {
				"ok": false,
				"error": "API key missing for %s — set it in Settings (user:// only)" % display,
			}
	return {
		"ok": true,
		"error": "",
		"model": model,
		"base_url": base_url,
		"model_name": model_name,
		"role": role,
		"display_name": display,
	}


static func validate_selected_planner(cfg: ConfigFile = null) -> Dictionary:
	return validate_role_endpoint(get_selected_planner(cfg), ROLE_PLANNER)


static func validate_selected_coder(cfg: ConfigFile = null) -> Dictionary:
	return validate_role_endpoint(get_selected_coder(cfg), ROLE_CODER)


## Safe fields for session jsonl / logs. Never includes api_key or secret-bearing URLs.
static func model_log_fields(model: Dictionary) -> Dictionary:
	var base: String = str(model.get("base_url", ""))
	var safe_url: String = ""
	if not _url_looks_secret(base):
		safe_url = base
	return {
		"model_id": str(model.get("id", "")),
		"role": normalize_role(str(model.get("role", ROLE_CODER))),
		"display_name": str(model.get("display_name", "")),
		"kind": str(model.get("kind", "")),
		"model_name": str(model.get("model_name", "")),
		"base_url": safe_url,
	}


static func _url_looks_secret(url: String) -> bool:
	var u: String = url.to_lower()
	if u.find("api_key=") >= 0 or u.find("apikey=") >= 0:
		return true
	if u.find("token=") >= 0 or u.find("key=") >= 0:
		return true
	# userinfo in URL
	if u.find("@") >= 0 and u.find("://") >= 0:
		var after: String = u.get_slice("://", 1)
		if after.find("@") >= 0:
			return true
	return false


static func list_extra_tools(cfg: ConfigFile = null) -> Array[Dictionary]:
	var c: ConfigFile = cfg if cfg != null else load_config()
	var ids: PackedStringArray = PackedStringArray(c.get_value(SECTION_EXTRA_TOOLS, KEY_EXTRA_IDS, PackedStringArray()))
	var out: Array[Dictionary] = []
	for id: String in ids:
		var section: String = _extra_section(id)
		if not c.has_section(section):
			continue
		out.append({
			"id": id,
			"name": str(c.get_value(section, "name", "")),
			"path": str(c.get_value(section, "path", "")),
		})
	return out


static func upsert_extra_tool(tool: Dictionary, cfg: ConfigFile = null) -> String:
	var c: ConfigFile = cfg if cfg != null else load_config()
	var id: String = str(tool.get("id", ""))
	if id.is_empty():
		id = make_extra_tool_id()
		tool["id"] = id

	var ids: PackedStringArray = PackedStringArray(c.get_value(SECTION_EXTRA_TOOLS, KEY_EXTRA_IDS, PackedStringArray()))
	if not ids.has(id):
		ids.append(id)
		c.set_value(SECTION_EXTRA_TOOLS, KEY_EXTRA_IDS, ids)

	var section: String = _extra_section(id)
	c.set_value(section, "name", str(tool.get("name", "")))
	# Missing paths are saved on purpose; they fail only the job that needs them.
	c.set_value(section, "path", str(tool.get("path", "")))
	save_config(c)
	return id


static func remove_extra_tool(tool_id: String, cfg: ConfigFile = null) -> void:
	var c: ConfigFile = cfg if cfg != null else load_config()
	var ids: PackedStringArray = PackedStringArray(c.get_value(SECTION_EXTRA_TOOLS, KEY_EXTRA_IDS, PackedStringArray()))
	var next: PackedStringArray = PackedStringArray()
	for id: String in ids:
		if id != tool_id:
			next.append(id)
	c.set_value(SECTION_EXTRA_TOOLS, KEY_EXTRA_IDS, next)
	var section: String = _extra_section(tool_id)
	if c.has_section(section):
		c.erase_section(section)
	save_config(c)


static func get_open_session_ids(cfg: ConfigFile = null) -> PackedStringArray:
	var c: ConfigFile = cfg if cfg != null else load_config()
	return PackedStringArray(
		c.get_value(SECTION_SESSIONS, KEY_OPEN_SESSION_IDS, PackedStringArray())
	)


static func set_open_session_ids(ids: PackedStringArray, cfg: ConfigFile = null) -> void:
	var c: ConfigFile = cfg if cfg != null else load_config()
	c.set_value(SECTION_SESSIONS, KEY_OPEN_SESSION_IDS, ids)
	save_config(c)


static func _model_section(model_id: String) -> String:
	return "model.%s" % model_id


static func _extra_section(tool_id: String) -> String:
	return "extra.%s" % tool_id


static func _read_model(c: ConfigFile, model_id: String) -> Dictionary:
	var section: String = _model_section(model_id)
	var kind: String = str(c.get_value(section, "kind", KIND_LOCAL))
	var role: String = normalize_role(str(c.get_value(section, "role", ROLE_CODER)))
	var ctx: int = int(c.get_value(section, "context_length", 0))
	if ctx <= 0:
		ctx = default_context_length(role)
	var model: Dictionary = {
		"id": model_id,
		"display_name": str(c.get_value(section, "display_name", model_id)),
		"kind": kind,
		"role": role,
		"base_url": str(c.get_value(section, "base_url", "")),
		"model_name": str(c.get_value(section, "model_name", "")),
		"context_length": ctx,
		"accepts_images": bool(c.get_value(section, "accepts_images", false)),
		"provider": str(c.get_value(section, "provider", "")),
	}
	if kind == KIND_EXTERNAL:
		model["api_key"] = str(c.get_value(section, "api_key", ""))
	return model
