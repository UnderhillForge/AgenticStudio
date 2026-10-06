class_name AgenticStudioContextBudget
extends RefCounted
## Pack prompt context into a role budget. Never summarizes.
## Trim order: session jsonl (oldest first), then older lines of the cited page.
## Never trim: op schema, page_id, last play error.

const CHARS_PER_TOKEN: float = 4.0


static func estimate_tokens(text: String) -> int:
	if text.is_empty():
		return 0
	return int(ceil(float(text.length()) / CHARS_PER_TOKEN))


static func default_budget(role: String) -> int:
	var r: String = role.strip_edges().to_lower()
	if r == "planner":
		return 32768
	return 8192


static func resolve_budget(model: Dictionary) -> int:
	var n: int = int(model.get("context_length", 0))
	if n > 0:
		return n
	return default_budget(str(model.get("role", "coder")))


## required: Dictionary with fixed keys that must fit (schema, page_id, last_play_error, system, …).
## session_lines: oldest → newest jsonl line strings (trim from the front / oldest).
## page_lines: page note lines oldest → newest (trim from the front / older).
## Returns {ok, error, messages_user_extra, used_tokens, budget, trimmed_session, trimmed_page}.
static func pack(
	required: Dictionary,
	session_lines: PackedStringArray,
	page_lines: PackedStringArray,
	budget: int
) -> Dictionary:
	var required_parts: PackedStringArray = PackedStringArray()
	# Fixed order; these are never trimmed.
	for key: String in ["system", "op_schema", "page_id", "last_play_error", "prompt"]:
		if required.has(key):
			var part: String = str(required[key])
			if not part.is_empty():
				required_parts.append(part)
	for key2: String in required.keys():
		if key2 in ["system", "op_schema", "page_id", "last_play_error", "prompt"]:
			continue
		var extra: String = str(required[key2])
		if not extra.is_empty():
			required_parts.append(extra)

	var required_text: String = "\n\n".join(required_parts)
	var required_tokens: int = estimate_tokens(required_text)
	if required_tokens > budget:
		return {
			"ok": false,
			"error": "context budget exceeded: required block needs %d tokens, budget is %d" % [
				required_tokens, budget
			],
			"used_tokens": required_tokens,
			"budget": budget,
			"messages_user_extra": "",
			"trimmed_session": session_lines.size(),
			"trimmed_page": page_lines.size(),
		}

	var remaining: int = budget - required_tokens
	var kept_session: PackedStringArray = session_lines.duplicate()
	var trimmed_session: int = 0
	while not kept_session.is_empty() and estimate_tokens("\n".join(kept_session)) > remaining:
		# Drop oldest session line first.
		kept_session.remove_at(0)
		trimmed_session += 1

	var session_block: String = "\n".join(kept_session)
	var after_session: int = remaining - estimate_tokens(session_block)
	if after_session < 0:
		after_session = 0

	var kept_page: PackedStringArray = page_lines.duplicate()
	var trimmed_page: int = 0
	while not kept_page.is_empty() and estimate_tokens("\n".join(kept_page)) > after_session:
		kept_page.remove_at(0)
		trimmed_page += 1

	var page_block: String = "\n".join(kept_page)
	var extras: PackedStringArray = PackedStringArray()
	if not session_block.is_empty():
		extras.append("Session log (trimmed):\n" + session_block)
	if not page_block.is_empty():
		extras.append("Page notes (trimmed):\n" + page_block)
	var extra_text: String = "\n\n".join(extras)
	var used: int = required_tokens + estimate_tokens(extra_text)
	return {
		"ok": true,
		"error": "",
		"messages_user_extra": extra_text,
		"used_tokens": used,
		"budget": budget,
		"trimmed_session": trimmed_session,
		"trimmed_page": trimmed_page,
	}
