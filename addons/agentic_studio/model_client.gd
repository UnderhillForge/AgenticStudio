class_name AgenticStudioModelClient
extends RefCounted
## OpenAI-compatible chat completions for Plan and tool-using execute modes.

const SceneToolsScript = preload("res://addons/agentic_studio/scene_tools.gd")
const ShotSupportScript = preload("res://addons/agentic_studio/screenshot_support.gd")

const PLAN_SYSTEM_PROMPT: String = (
	"You are the AgenticStudio planner. You do not apply ops and you never write "
	+ "scenes, project.godot, or autoloads. "
	+ "You may call list_pages, get_page, list_dir, read_file, screenshot, and check_page_drift "
	+ "to inspect pages, text files under res://, editor/game views, and page/scene drift. "
	+ "Pages are .tres files under res://studio/characters/ and res://studio/assets/. "
	+ "Prefer get_page with the page title string (for example Goblin Shaman). "
	+ "screenshot target is editor_2d, editor_3d, or play (play needs a running game). "
	+ "Do not call write_file, delete_file, link, create_asset, add_node, set_property, "
	+ "or any other write tool — those replies are discarded. "
	+ "Your plan MUST name: (1) page_id, (2) the intended op for the coder, "
	+ "(3) the play check that counts as done. "
	+ "Do not claim you edited the project or performed any write."
)

const EXECUTE_SYSTEM_PROMPT: String = (
	"You are executing inside the Godot editor via AgenticStudio. "
	+ "Planning is not executing. Only these tools exist: "
	+ "read_scene, add_node, set_property, play_scene, list_pages, get_page, link, "
	+ "create_asset, list_dir, read_file, write_file, delete_file, screenshot, and check_page_drift. "
	+ "Scene and resource writes require page_id (e.g. goblin_shaman). "
	+ "create_asset copies the known stand-in GLB into res://inbox/, imports it, "
	+ "instances it, and links a new asset page from the named character page. "
	+ "list_dir and read_file inspect text under res://. "
	+ "write_file creates or replaces a text file under res://; script body always asks. "
	+ "delete_file removes a page, scene, or script under res:// and always asks. "
	+ "screenshot captures editor_2d, editor_3d, or play to a PNG path; not a scene write. "
	+ "To attach a new script to a node: write_file the .gd with page_id, then set_property "
	+ "path=Node property=script value=res://that_script.gd page_id=.... "
	+ "Do not claim a node was added unless add_node or create_asset returned ok. "
	+ "There is no project-settings tool. At most 4 write tool calls per job."
)

const DEFAULT_TIMEOUT_SEC: float = 120.0
const MAX_TOOL_ROUNDS: int = 4


static func completions_url(base_url: String) -> String:
	var base: String = base_url.strip_edges().trim_suffix("/")
	return base + "/chat/completions"


static func build_headers(model: Dictionary) -> PackedStringArray:
	var headers: PackedStringArray = PackedStringArray([
		"Content-Type: application/json",
		"Accept: application/json",
	])
	# Bearer only for kind=external. Local planners/coders never send Authorization.
	if str(model.get("kind", "")) == AgenticStudioConfig.KIND_EXTERNAL:
		var api_key: String = str(model.get("api_key", "")).strip_edges()
		if not api_key.is_empty():
			headers.append("Authorization: Bearer %s" % api_key)
	return headers


static func build_plan_headers(model: Dictionary) -> PackedStringArray:
	return build_headers(model)


static func build_plan_body(model: Dictionary, user_prompt: String) -> String:
	## Single-shot plan body without a prior tool loop (kept for simple callers).
	var payload: Dictionary = {
		"model": str(model.get("model_name", "")),
		"messages": [
			{"role": "system", "content": PLAN_SYSTEM_PROMPT},
			{"role": "user", "content": user_prompt},
		],
		"tools": SceneToolsScript.plan_tool_definitions(),
	}
	return JSON.stringify(payload)


static func build_chat_body(
	model: Dictionary,
	messages: Array,
	include_tools: bool,
	plan_only_tools: bool = false
) -> String:
	var payload: Dictionary = {
		"model": str(model.get("model_name", "")),
		"messages": messages,
	}
	if include_tools:
		if plan_only_tools:
			payload["tools"] = SceneToolsScript.plan_tool_definitions()
		else:
			payload["tools"] = SceneToolsScript.tool_definitions()
	return JSON.stringify(payload)


static func validate_model_endpoint(model: Dictionary, expected_role: String = "") -> Dictionary:
	var checked: Dictionary = AgenticStudioConfig.validate_role_endpoint(model, expected_role)
	if not bool(checked.get("ok", false)):
		return {"ok": false, "error": str(checked.get("error", "")), "url": "", "headers": PackedStringArray()}
	var base_url: String = str(checked.get("base_url", ""))
	return {
		"ok": true,
		"error": "",
		"url": completions_url(base_url),
		"headers": build_headers(model),
	}


## True when a planner reply tried to write (discard — never apply).
static func planner_response_has_write(content: String, tool_calls: Array) -> bool:
	for call_v: Variant in tool_calls:
		if typeof(call_v) != TYPE_DICTIONARY:
			continue
		var fn: Dictionary = (call_v as Dictionary).get("function", {})
		var name: String = str(fn.get("name", ""))
		if AgenticStudioSceneTools.is_write_tool(name):
			return true
		if not AgenticStudioSceneTools.is_plan_tool(name) and name in [
			"add_node", "set_property", "write_file", "delete_file", "create_asset", "link"
		]:
			return true
	var lower: String = content.to_lower()
	for marker: String in ['"write_file"', '"delete_file"', '"add_node"', '"set_property"', '"create_asset"']:
		if lower.find(marker) >= 0:
			return true
	return false


static func build_plan_request(model: Dictionary, user_prompt: String) -> Dictionary:
	## Returns {ok, error, url, headers, body}. Does not perform I/O.
	var endpoint: Dictionary = validate_model_endpoint(model)
	if not bool(endpoint.get("ok", false)):
		return {
			"ok": false,
			"error": str(endpoint.get("error", "")),
			"url": "",
			"headers": PackedStringArray(),
			"body": "",
		}
	return {
		"ok": true,
		"error": "",
		"url": str(endpoint.get("url", "")),
		"headers": endpoint.get("headers", PackedStringArray()),
		"body": build_plan_body(model, user_prompt),
	}


static func build_chat_request(
	model: Dictionary,
	messages: Array,
	include_tools: bool,
	plan_only_tools: bool = false
) -> Dictionary:
	var endpoint: Dictionary = validate_model_endpoint(model)
	if not bool(endpoint.get("ok", false)):
		return {
			"ok": false,
			"error": str(endpoint.get("error", "")),
			"url": "",
			"headers": PackedStringArray(),
			"body": "",
		}
	return {
		"ok": true,
		"error": "",
		"url": str(endpoint.get("url", "")),
		"headers": endpoint.get("headers", PackedStringArray()),
		"body": build_chat_body(model, messages, include_tools, plan_only_tools),
	}


static func initial_execute_messages(user_prompt: String) -> Array:
	return [
		{"role": "system", "content": EXECUTE_SYSTEM_PROMPT},
		{"role": "user", "content": user_prompt},
	]


static func initial_plan_messages(user_prompt: String) -> Array:
	return [
		{"role": "system", "content": PLAN_SYSTEM_PROMPT},
		{"role": "user", "content": user_prompt},
	]


static func parse_assistant_text(response_body: String) -> String:
	var message: Dictionary = parse_assistant_message(response_body)
	return str(message.get("content", "")).strip_edges()


static func parse_assistant_message(response_body: String) -> Dictionary:
	## Returns {role, content, tool_calls:Array} from an OpenAI-style body.
	var empty: Dictionary = {"role": "assistant", "content": "", "tool_calls": []}
	var parsed: Variant = JSON.parse_string(response_body)
	if typeof(parsed) != TYPE_DICTIONARY:
		return empty
	var data: Dictionary = parsed
	var choices: Variant = data.get("choices", null)
	if choices is Array and (choices as Array).size() > 0:
		var first: Variant = (choices as Array)[0]
		if first is Dictionary:
			var message: Variant = (first as Dictionary).get("message", {})
			if message is Dictionary:
				return normalize_assistant_message(message)
	if data.has("response"):
		return {
			"role": "assistant",
			"content": str(data.get("response", "")).strip_edges(),
			"tool_calls": [],
		}
	return empty


static func normalize_assistant_message(message: Dictionary) -> Dictionary:
	var content_var: Variant = message.get("content", "")
	var content: String = ""
	if content_var != null:
		content = str(content_var).strip_edges()
	var tool_calls: Array = []
	var raw_calls: Variant = message.get("tool_calls", [])
	if raw_calls is Array:
		for item: Variant in raw_calls:
			if item is Dictionary:
				tool_calls.append(normalize_tool_call(item))
	var from_content: bool = false
	# Some local models (e.g. Ollama qwen) emit a tool call as JSON text.
	if tool_calls.is_empty() and not content.is_empty():
		var extracted: Array = extract_tool_calls_from_content(content)
		if not extracted.is_empty():
			tool_calls = extracted
			from_content = true
	var out: Dictionary = {
		"role": "assistant",
		"content": content,
		"tool_calls": tool_calls,
		"from_content_tools": from_content,
	}
	return out


static func extract_tool_calls_from_content(content: String) -> Array:
	var trimmed: String = content.strip_edges()
	# Strip common markdown fences.
	if trimmed.begins_with("```"):
		var first_nl: int = trimmed.find("\n")
		if first_nl >= 0:
			trimmed = trimmed.substr(first_nl + 1)
		if trimmed.ends_with("```"):
			trimmed = trimmed.substr(0, trimmed.length() - 3).strip_edges()
	# Avoid parsing ordinary prose.
	if trimmed.is_empty() or (not trimmed.begins_with("{") and not trimmed.begins_with("[")):
		return []
	var parsed: Variant = _parse_json_quiet(trimmed)
	if parsed == null:
		# Models sometimes emit bare identifiers: {"name": add_node, ...}
		parsed = _parse_json_quiet(_quote_bare_json_identifiers(trimmed))
	var out: Array = []
	if typeof(parsed) == TYPE_DICTIONARY:
		var d: Dictionary = parsed
		if d.has("tool_calls") and d.get("tool_calls") is Array:
			for item: Variant in d.get("tool_calls"):
				if item is Dictionary:
					out.append(normalize_tool_call(item))
			return out
		if d.has("name") and d.has("arguments"):
			out.append(_content_dict_to_tool_call(d))
			return out
	if typeof(parsed) == TYPE_ARRAY:
		for item: Variant in parsed:
			if item is Dictionary and (item as Dictionary).has("name"):
				var one: Array = extract_tool_calls_from_content(JSON.stringify(item))
				out.append_array(one)
		return out
	# Concatenated objects: {"name":…}\n{"name":…} (common with local models).
	if parsed == null:
		out = _extract_concatenated_tool_json(trimmed)
	return out


static func _content_dict_to_tool_call(d: Dictionary) -> Dictionary:
	var args_var: Variant = d.get("arguments")
	var args_str: String = (
		JSON.stringify(args_var)
		if args_var is Dictionary or args_var is Array
		else str(args_var)
	)
	return normalize_tool_call({
		"id": "call_content_%d" % Time.get_ticks_msec(),
		"type": "function",
		"function": {
			"name": str(d.get("name", "")),
			"arguments": args_str,
		},
	})


static func _extract_concatenated_tool_json(text: String) -> Array:
	## Pull successive top-level {...} objects that look like tool calls.
	var out: Array = []
	var i: int = 0
	var n: int = text.length()
	while i < n:
		while i < n and text[i] <= " ":
			i += 1
		if i >= n or text[i] != "{":
			break
		var depth: int = 0
		var in_str: bool = false
		var escape: bool = false
		var end: int = -1
		for j: int in range(i, n):
			var ch: String = text[j]
			if in_str:
				if escape:
					escape = false
				elif ch == "\\":
					escape = true
				elif ch == "\"":
					in_str = false
				continue
			if ch == "\"":
				in_str = true
				continue
			if ch == "{":
				depth += 1
			elif ch == "}":
				depth -= 1
				if depth == 0:
					end = j
					break
		if end < 0:
			break
		var chunk: String = text.substr(i, end - i + 1)
		var parsed: Variant = _parse_json_quiet(chunk)
		if parsed == null:
			parsed = _parse_json_quiet(_quote_bare_json_identifiers(chunk))
		if typeof(parsed) == TYPE_DICTIONARY:
			var d: Dictionary = parsed
			if d.has("name") and d.has("arguments"):
				out.append(_content_dict_to_tool_call(d))
		i = end + 1
	return out


static func _parse_json_quiet(text: String) -> Variant:
	var json := JSON.new()
	if json.parse(text) != OK:
		return null
	return json.data


static func _quote_bare_json_identifiers(text: String) -> String:
	## Turns {"name": add_node, ...} into {"name": "add_node", ...}.
	var re := RegEx.new()
	var err: Error = re.compile(":\\s*([A-Za-z_][A-Za-z0-9_]*)\\s*([,}\\]])")
	if err != OK:
		return text
	var out: String = text
	var matches: Array[RegExMatch] = re.search_all(text)
	# Replace from the end so offsets stay valid.
	for i: int in range(matches.size() - 1, -1, -1):
		var m: RegExMatch = matches[i]
		var ident: String = m.get_string(1)
		if ident == "true" or ident == "false" or ident == "null":
			continue
		var start: int = m.get_start(1)
		var end: int = m.get_end(1)
		out = out.substr(0, start) + "\"%s\"" % ident + out.substr(end)
	return out


static func normalize_tool_call(call: Dictionary) -> Dictionary:
	var fn: Variant = call.get("function", {})
	var name: String = ""
	var arguments: String = "{}"
	if fn is Dictionary:
		name = str((fn as Dictionary).get("name", ""))
		var args_var: Variant = (fn as Dictionary).get("arguments", "{}")
		if args_var is Dictionary or args_var is Array:
			arguments = JSON.stringify(args_var)
		else:
			arguments = str(args_var)
			if arguments.is_empty():
				arguments = "{}"
	var id: String = str(call.get("id", ""))
	if id.is_empty():
		id = "call_%s_%d" % [name, Time.get_ticks_msec()]
	return {
		"id": id,
		"type": "function",
		"function": {
			"name": name,
			"arguments": arguments,
		},
	}


static func parse_tool_arguments(arguments: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(arguments)
	if typeof(parsed) == TYPE_DICTIONARY:
		return parsed
	return {}


static func model_accepts_images(model: Dictionary) -> bool:
	return bool(model.get("accepts_images", false))


static func apply_pending_shots(
	messages: Array,
	model: Dictionary,
	tools: AgenticStudioSceneTools
) -> void:
	## If the model accepts images, attach pending PNGs to the next user/tool message.
	## Otherwise log paths on the job via a synthetic note in messages is skipped —
	## the tool result already includes the path; clear pending without failing.
	if tools == null:
		return
	var paths: PackedStringArray = tools.pending_shot_paths
	if paths.is_empty():
		return
	if not model_accepts_images(model):
		# Path already logged in the tool result. Do not fail the job.
		tools.pending_shot_paths = PackedStringArray()
		return
	var parts: Array = []
	parts.append({
		"type": "text",
		"text": "Attached screenshot(s) from the previous tool call(s):",
	})
	var attached: int = 0
	for path: String in paths:
		var url: String = ShotSupportScript.file_to_data_url(path)
		if url.is_empty():
			parts.append({
				"type": "text",
				"text": "shot missing or unreadable: %s" % path,
			})
			continue
		parts.append({
			"type": "image_url",
			"image_url": {"url": url},
		})
		parts.append({"type": "text", "text": "path: %s" % path})
		attached += 1
	if attached > 0 or parts.size() > 1:
		messages.append({"role": "user", "content": parts})
	tools.pending_shot_paths = PackedStringArray()


static func tool_result_message(tool_call_id: String, result: Dictionary) -> Dictionary:
	return {
		"role": "tool",
		"tool_call_id": tool_call_id,
		"content": JSON.stringify(result),
	}


static func assistant_message_for_history(message: Dictionary) -> Dictionary:
	## Strip to fields the API expects when replaying an assistant turn.
	var out: Dictionary = {
		"role": "assistant",
		"content": message.get("content", ""),
	}
	var from_content: bool = bool(message.get("from_content_tools", false))
	var calls: Array = message.get("tool_calls", [])
	# Content-emitted tool JSON stays as assistant content; native tool_calls use the field.
	if calls.size() > 0 and not from_content:
		out["tool_calls"] = calls
		if out["content"] == null or str(out["content"]).is_empty():
			out["content"] = ""
	return out


static func tool_results_user_message(results: Array) -> Dictionary:
	## Fallback turn for models that emit tools as plain JSON content.
	var lines: PackedStringArray = PackedStringArray()
	lines.append("Tool results:")
	for item: Variant in results:
		lines.append(str(item))
	lines.append("Continue with another tool if needed, or finish.")
	return {
		"role": "user",
		"content": "\n".join(lines),
	}


static func http_request_result_label(result: int) -> String:
	match result:
		HTTPRequest.RESULT_SUCCESS:
			return "success"
		HTTPRequest.RESULT_CHUNKED_BODY_SIZE_MISMATCH:
			return "chunked_body_size_mismatch"
		HTTPRequest.RESULT_CANT_CONNECT:
			return "connection_refused"
		HTTPRequest.RESULT_CANT_RESOLVE:
			return "cant_resolve"
		HTTPRequest.RESULT_CONNECTION_ERROR:
			return "connection_error"
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return "tls_handshake_error"
		HTTPRequest.RESULT_NO_RESPONSE:
			return "no_response"
		HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED:
			return "body_size_limit_exceeded"
		HTTPRequest.RESULT_BODY_DECOMPRESS_FAILED:
			return "body_decompress_failed"
		HTTPRequest.RESULT_REQUEST_FAILED:
			return "request_failed"
		HTTPRequest.RESULT_DOWNLOAD_FILE_CANT_OPEN:
			return "download_file_cant_open"
		HTTPRequest.RESULT_DOWNLOAD_FILE_WRITE_ERROR:
			return "download_file_write_error"
		HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED:
			return "redirect_limit_reached"
		HTTPRequest.RESULT_TIMEOUT:
			return "timeout"
		_:
			return "http_result_%d" % result


static func format_failure_log(status_code: int, result_label: String, body: String) -> String:
	var trimmed: String = body.strip_edges()
	if trimmed.length() > 4000:
		trimmed = trimmed.substr(0, 4000) + "…"
	return "Request failed: status=%d result=%s body=%s" % [status_code, result_label, trimmed]


## Blocking OpenAI-compatible Plan call for live checks (not used by the dock UI).
static func request_plan_via_client(
	model: Dictionary,
	user_prompt: String,
	timeout_sec: float = DEFAULT_TIMEOUT_SEC
) -> Dictionary:
	var built: Dictionary = build_plan_request(model, user_prompt)
	if not bool(built.get("ok", false)):
		return {
			"ok": false,
			"status": 0,
			"result": "build_error",
			"body": "",
			"text": "",
			"message": {},
			"error": str(built.get("error", "build failed")),
		}
	var raw: Dictionary = _post_json(
		str(built.get("url", "")),
		built.get("headers", PackedStringArray()),
		str(built.get("body", "")),
		timeout_sec
	)
	if not bool(raw.get("ok", false)):
		raw["text"] = ""
		raw["message"] = {}
		return raw
	var text: String = parse_assistant_text(str(raw.get("body", "")))
	if text.is_empty():
		return {
			"ok": false,
			"status": int(raw.get("status", 0)),
			"result": "empty_assistant",
			"body": str(raw.get("body", "")),
			"text": "",
			"message": {},
			"error": format_failure_log(
				int(raw.get("status", 0)),
				"empty_assistant",
				str(raw.get("body", ""))
			),
		}
	return {
		"ok": true,
		"status": int(raw.get("status", 0)),
		"result": "success",
		"body": str(raw.get("body", "")),
		"text": text,
		"message": parse_assistant_message(str(raw.get("body", ""))),
		"error": "",
	}


static func request_chat_via_client(
	model: Dictionary,
	messages: Array,
	include_tools: bool,
	timeout_sec: float = DEFAULT_TIMEOUT_SEC,
	plan_only_tools: bool = false
) -> Dictionary:
	var built: Dictionary = build_chat_request(
		model,
		messages,
		include_tools,
		plan_only_tools
	)
	if not bool(built.get("ok", false)):
		return {
			"ok": false,
			"status": 0,
			"result": "build_error",
			"body": "",
			"text": "",
			"message": {},
			"error": str(built.get("error", "build failed")),
		}
	var raw: Dictionary = _post_json(
		str(built.get("url", "")),
		built.get("headers", PackedStringArray()),
		str(built.get("body", "")),
		timeout_sec
	)
	if not bool(raw.get("ok", false)):
		raw["text"] = ""
		raw["message"] = {}
		return raw
	var message: Dictionary = parse_assistant_message(str(raw.get("body", "")))
	var text: String = str(message.get("content", "")).strip_edges()
	var tool_calls: Array = message.get("tool_calls", [])
	if text.is_empty() and tool_calls.is_empty():
		return {
			"ok": false,
			"status": int(raw.get("status", 0)),
			"result": "empty_assistant",
			"body": str(raw.get("body", "")),
			"text": "",
			"message": message,
			"error": format_failure_log(
				int(raw.get("status", 0)),
				"empty_assistant",
				str(raw.get("body", ""))
			),
		}
	return {
		"ok": true,
		"status": int(raw.get("status", 0)),
		"result": "success",
		"body": str(raw.get("body", "")),
		"text": text,
		"message": message,
		"error": "",
	}


static func _post_json(
	url: String,
	headers: PackedStringArray,
	req_body: String,
	timeout_sec: float
) -> Dictionary:
	var parsed: Dictionary = _parse_url(url)
	if not bool(parsed.get("ok", false)):
		return {
			"ok": false,
			"status": 0,
			"result": "bad_url",
			"body": "",
			"error": str(parsed.get("error", "bad url")),
		}

	var client := HTTPClient.new()
	var tls: TLSOptions = null
	if bool(parsed.get("tls", false)):
		tls = TLSOptions.client()
	var connect_err: Error = client.connect_to_host(
		str(parsed.get("host", "")),
		int(parsed.get("port", 80)),
		tls
	)
	if connect_err != OK:
		return {
			"ok": false,
			"status": 0,
			"result": "connection_refused",
			"body": "",
			"error": "connect_to_host failed: %d" % connect_err,
		}

	var deadline: float = Time.get_ticks_msec() / 1000.0 + timeout_sec
	while client.get_status() == HTTPClient.STATUS_CONNECTING \
			or client.get_status() == HTTPClient.STATUS_RESOLVING:
		if Time.get_ticks_msec() / 1000.0 > deadline:
			client.close()
			return {
				"ok": false,
				"status": 0,
				"result": "timeout",
				"body": "",
				"error": "timeout while connecting",
			}
		client.poll()
		OS.delay_msec(10)

	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		var st: int = client.get_status()
		client.close()
		return {
			"ok": false,
			"status": 0,
			"result": "connection_refused",
			"body": "",
			"error": "not connected (status %d)" % st,
		}

	var req_err: Error = client.request(
		HTTPClient.METHOD_POST,
		str(parsed.get("path", "/")),
		headers,
		req_body
	)
	if req_err != OK:
		client.close()
		return {
			"ok": false,
			"status": 0,
			"result": "request_failed",
			"body": "",
			"error": "HTTPClient.request failed: %d" % req_err,
		}

	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		if Time.get_ticks_msec() / 1000.0 > deadline:
			client.close()
			return {
				"ok": false,
				"status": 0,
				"result": "timeout",
				"body": "",
				"error": "timeout while requesting",
			}
		client.poll()
		OS.delay_msec(10)

	var response_body: PackedByteArray = PackedByteArray()
	while client.get_status() == HTTPClient.STATUS_BODY:
		if Time.get_ticks_msec() / 1000.0 > deadline:
			client.close()
			return {
				"ok": false,
				"status": client.get_response_code(),
				"result": "timeout",
				"body": response_body.get_string_from_utf8(),
				"error": "timeout while reading body",
			}
		client.poll()
		var chunk: PackedByteArray = client.read_response_body_chunk()
		if chunk.size() > 0:
			response_body.append_array(chunk)
		else:
			OS.delay_msec(10)

	var status_code: int = client.get_response_code()
	client.close()
	var body_text: String = response_body.get_string_from_utf8()
	if status_code != 200:
		return {
			"ok": false,
			"status": status_code,
			"result": "http_%d" % status_code,
			"body": body_text,
			"error": format_failure_log(status_code, "http_%d" % status_code, body_text),
		}
	return {
		"ok": true,
		"status": status_code,
		"result": "success",
		"body": body_text,
		"error": "",
	}


static func _parse_url(url: String) -> Dictionary:
	var tls: bool = false
	var rest: String = url
	if rest.begins_with("https://"):
		tls = true
		rest = rest.substr(8)
	elif rest.begins_with("http://"):
		rest = rest.substr(7)
	else:
		return {"ok": false, "error": "URL must be http(s): %s" % url}

	var slash: int = rest.find("/")
	var hostport: String = rest if slash < 0 else rest.substr(0, slash)
	var path: String = "/" if slash < 0 else rest.substr(slash)
	if path.is_empty():
		path = "/"

	var host: String = hostport
	var port: int = 443 if tls else 80
	var colon: int = hostport.rfind(":")
	# Avoid treating IPv6 as host:port; debian.local-style hosts are fine.
	if colon > 0 and hostport.find("]") < 0:
		host = hostport.substr(0, colon)
		port = int(hostport.substr(colon + 1))

	if host.is_empty():
		return {"ok": false, "error": "empty host in URL"}
	return {"ok": true, "host": host, "port": port, "path": path, "tls": tls}
