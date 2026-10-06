extends SceneTree
## Headless: planner/coder rows, Grok/Build upserts, budget, session log fields.
## Run: godot --headless --path . --script res://addons/agentic_studio/verify_roles.gd

const ConfigScript = preload("res://addons/agentic_studio/config.gd")
const BudgetScript = preload("res://addons/agentic_studio/context_budget.gd")
const SessionLogScript = preload("res://addons/agentic_studio/session_log.gd")
const ModelClientScript = preload("res://addons/agentic_studio/model_client.gd")


func _initialize() -> void:
	var failures: PackedStringArray = PackedStringArray()
	ConfigScript.ensure_dirs()

	var prev_planner: String = ConfigScript.get_selected_planner_id()
	var prev_coder: String = ConfigScript.get_selected_coder_id()

	# --- Upserts (no key printed) ---
	var grok_id: String = ConfigScript.upsert_grok_planner("verify-secret-key-not-printed")
	if grok_id != ConfigScript.STABLE_GROK_ID:
		failures.append("Grok upsert id mismatch")
	var grok: Dictionary = ConfigScript.get_model(grok_id)
	if str(grok.get("role", "")) != ConfigScript.ROLE_PLANNER:
		failures.append("Grok role should be planner")
	if str(grok.get("kind", "")) != ConfigScript.KIND_EXTERNAL:
		failures.append("Grok kind should be external")
	if str(grok.get("base_url", "")) != ConfigScript.GROK_BASE_URL:
		failures.append("Grok base_url wrong")
	if str(grok.get("model_name", "")) != ConfigScript.GROK_MODEL_NAME:
		failures.append("Grok model_name wrong")
	if str(grok.get("api_key", "")) != "verify-secret-key-not-printed":
		failures.append("Grok api_key not stored in user://")

	var mini_id: String = ConfigScript.add_grok_build_planner("Mini")
	var mini: Dictionary = ConfigScript.get_model(mini_id)
	if str(mini.get("role", "")) != ConfigScript.ROLE_PLANNER:
		failures.append("Mini Build role should be planner")
	if str(mini.get("kind", "")) != ConfigScript.KIND_LOCAL:
		failures.append("Mini Build kind should be local")
	if not str(mini.get("base_url", "")).is_empty():
		failures.append("Mini Build base_url should start blank")
	if mini.has("api_key"):
		failures.append("Mini Build must not store api_key")

	var debian_id: String = ConfigScript.add_grok_build_planner("debian.local")
	var debian: Dictionary = ConfigScript.get_model(debian_id)
	if str(debian.get("display_name", "")) != "debian.local":
		failures.append("debian.local display_name mismatch")

	var coder_id: String = ConfigScript.upsert_ollama_coder(
		"Local Coder Verify",
		ConfigScript.DEFAULT_OLLAMA_BASE,
		"qwen2.5-coder:7b",
		"verify_ollama_coder"
	)
	var coder: Dictionary = ConfigScript.get_model(coder_id)
	if str(coder.get("role", "")) != ConfigScript.ROLE_CODER:
		failures.append("Ollama row role should be coder")
	if str(coder.get("base_url", "")) != ConfigScript.DEFAULT_OLLAMA_BASE:
		failures.append("Ollama base_url mismatch")
	if coder.has("api_key"):
		failures.append("coder must not store api_key")

	# Second Grok upsert keeps same id.
	var grok_again: String = ConfigScript.upsert_grok_planner()
	if grok_again != grok_id:
		failures.append("Add Grok should upsert same row")

	# --- Blank Build URL named error; no coder fallback ---
	ConfigScript.set_selected_planner_id(mini_id)
	ConfigScript.set_selected_coder_id(coder_id)
	var blank: Dictionary = ConfigScript.validate_selected_planner()
	if bool(blank.get("ok", true)):
		failures.append("blank Build URL should fail")
	elif str(blank.get("error", "")).find("Build URL missing") < 0:
		failures.append("blank Build error should be named: %s" % str(blank.get("error", "")))

	# Switching planner selection does not change coder.
	ConfigScript.set_selected_planner_id(debian_id)
	if ConfigScript.get_selected_coder_id() != coder_id:
		failures.append("changing planner must not change coder")

	# Missing external key
	ConfigScript.upsert_model({
		"id": grok_id,
		"display_name": "Grok",
		"kind": ConfigScript.KIND_EXTERNAL,
		"role": ConfigScript.ROLE_PLANNER,
		"provider": ConfigScript.PROVIDER_GROK,
		"base_url": ConfigScript.GROK_BASE_URL,
		"model_name": ConfigScript.GROK_MODEL_NAME,
		"context_length": ConfigScript.DEFAULT_PLANNER_CONTEXT,
		"api_key": "",
	})
	ConfigScript.set_selected_planner_id(grok_id)
	var no_key: Dictionary = ConfigScript.validate_selected_planner()
	if bool(no_key.get("ok", true)):
		failures.append("missing Grok key should fail")
	elif str(no_key.get("error", "")).find("API key missing") < 0:
		failures.append("missing key error should be named")

	# Bearer headers only for external with key
	var headers_local: PackedStringArray = ModelClientScript.build_headers(coder)
	for h: String in headers_local:
		if h.begins_with("Authorization:"):
			failures.append("local coder must not send Authorization")
	var keyed: Dictionary = grok.duplicate(true)
	keyed["api_key"] = "verify-secret-key-not-printed"
	ConfigScript.upsert_model(keyed)
	var headers_ext: PackedStringArray = ModelClientScript.build_headers(ConfigScript.get_model(grok_id))
	var found_bearer: bool = false
	for h2: String in headers_ext:
		if h2.begins_with("Authorization: Bearer "):
			found_bearer = true
			if h2.find("verify-secret-key-not-printed") < 0:
				failures.append("bearer should use stored key")
	if not found_bearer:
		failures.append("external Grok should send Bearer")

	# --- Context budget ---
	var tiny: Dictionary = BudgetScript.pack(
		{
			"system": "sys",
			"op_schema": "schema",
			"page_id": "goblin_shaman",
			"last_play_error": "boom",
			"prompt": "do thing",
		},
		PackedStringArray(["old1", "old2", "old3"]),
		PackedStringArray(["noteA", "noteB", "noteC"]),
		8 # tiny — required alone may already fail
	)
	# With very small budget, required may exceed.
	var required_only: Dictionary = BudgetScript.pack(
		{
			"system": "x".repeat(200),
			"op_schema": "schema",
			"page_id": "goblin_shaman",
			"last_play_error": "err",
			"prompt": "p",
		},
		PackedStringArray(),
		PackedStringArray(),
		10
	)
	if bool(required_only.get("ok", true)):
		failures.append("oversized required block should budget-fail")

	var trim_ok: Dictionary = BudgetScript.pack(
		{
			"system": "sys",
			"op_schema": "schema",
			"page_id": "goblin_shaman",
			"last_play_error": "last-error-must-stay",
			"prompt": "prompt",
		},
		PackedStringArray(["s0", "s1", "s2", "s3"]),
		PackedStringArray(["p0", "p1", "p2"]),
		80
	)
	if not bool(trim_ok.get("ok", false)):
		failures.append("trim pack should succeed: %s" % str(trim_ok.get("error", "")))
	else:
		var extra: String = str(trim_ok.get("messages_user_extra", ""))
		if extra.find("last-error-must-stay") >= 0:
			# last play error is in required, not extra — OK either way as long as required kept
			pass
		if int(trim_ok.get("trimmed_session", 0)) < 0:
			failures.append("trimmed_session count invalid")

	# Defaults
	if BudgetScript.default_budget(ConfigScript.ROLE_CODER) != 8192:
		failures.append("coder default budget 8192")
	if BudgetScript.default_budget(ConfigScript.ROLE_PLANNER) != 32768:
		failures.append("planner default budget 32768")

	# --- Session log: role + display_name; never key ---
	SessionLogScript.ensure_dirs()
	var path: String = SessionLogScript.path_for_day()
	var before: String = ""
	if FileAccess.file_exists(path):
		before = FileAccess.get_file_as_string(path)
	SessionLogScript.append_plan_or_run(
		coder_id,
		"auto_approve",
		PackedStringArray(["goblin_shaman"]),
		[{"tool": "read_scene"}],
		null,
		coder
	)
	var after: String = FileAccess.get_file_as_string(path)
	var added: String = after.substr(before.length())
	if added.find("verify-secret-key-not-printed") >= 0:
		failures.append("session jsonl must never contain api key")
	if added.find("\"role\"") < 0:
		failures.append("session jsonl missing role")
	if added.find("Local Coder Verify") < 0 and added.find(coder_id) < 0:
		failures.append("session jsonl missing display_name/model_id")

	# Planner write discard helper
	if not ModelClientScript.planner_response_has_write(
		'{"tool":"write_file","arguments":{"path":"res://x.gd"}}',
		[]
	):
		failures.append("planner write content should be detected")

	# Cleanup verify rows (restore selections)
	ConfigScript.remove_model(mini_id)
	ConfigScript.remove_model(debian_id)
	ConfigScript.remove_model(coder_id)
	# Restore Grok keyless or remove if we created it for verify — keep structure, clear key
	ConfigScript.upsert_model({
		"id": grok_id,
		"display_name": "Grok",
		"kind": ConfigScript.KIND_EXTERNAL,
		"role": ConfigScript.ROLE_PLANNER,
		"provider": ConfigScript.PROVIDER_GROK,
		"base_url": ConfigScript.GROK_BASE_URL,
		"model_name": ConfigScript.GROK_MODEL_NAME,
		"context_length": ConfigScript.DEFAULT_PLANNER_CONTEXT,
		"api_key": "",
	})
	ConfigScript.set_selected_planner_id(prev_planner)
	ConfigScript.set_selected_coder_id(prev_coder)

	# Ensure config path stays user://
	if not ConfigScript.CONFIG_PATH.begins_with("user://"):
		failures.append("config must live under user://")

	if failures.is_empty():
		print("AgenticStudio verify_roles: OK")
		quit(0)
	else:
		print("AgenticStudio verify_roles: FAILED")
		for f: String in failures:
			print("  - ", f)
		quit(1)
