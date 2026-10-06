class_name AgenticStudioExecuteRunner
extends RefCounted
## Shared Run / Auto-approve tool loop.


static func run_sync(
	job: AgenticStudioJob,
	model: Dictionary,
	ask_writes: bool,
	tools: AgenticStudioSceneTools,
	ask_fn: Callable
) -> void:
	## Async despite the name: callers must await. Keeps the historical API name.
	var messages: Array = AgenticStudioModelClient.initial_execute_messages(job.prompt)
	var round_i: int = 0
	while round_i < AgenticStudioModelClient.MAX_TOOL_ROUNDS:
		AgenticStudioModelClient.apply_pending_shots(messages, model, tools)
		var response: Dictionary = AgenticStudioModelClient.request_chat_via_client(
			model,
			messages,
			true
		)
		if not await _handle_model_response(job, tools, messages, response):
			return

		var message: Dictionary = response.get("message", {})
		var tool_calls: Array = message.get("tool_calls", [])
		if tool_calls.is_empty():
			break

		round_i += 1
		job.append_log("Tool round %d/%d (%d call(s))" % [
			round_i,
			AgenticStudioModelClient.MAX_TOOL_ROUNDS,
			tool_calls.size(),
		])
		job.save()

		var from_content: bool = bool(message.get("from_content_tools", false))
		var content_results: Array = []
		for call_v: Variant in tool_calls:
			if typeof(call_v) != TYPE_DICTIONARY:
				continue
			var result_payload: Dictionary = await _handle_one_tool(
				job,
				tools,
				messages,
				call_v,
				ask_writes,
				ask_fn,
				from_content
			)
			if from_content:
				content_results.append(JSON.stringify(result_payload))

		if from_content and not content_results.is_empty():
			messages.append(AgenticStudioModelClient.tool_results_user_message(content_results))

		if round_i >= AgenticStudioModelClient.MAX_TOOL_ROUNDS:
			job.append_log(
				"Stopped after %d tool rounds." % AgenticStudioModelClient.MAX_TOOL_ROUNDS
			)
			job.save()
			break

	await finish_job(job, tools)


static func _handle_model_response(
	job: AgenticStudioJob,
	tools: AgenticStudioSceneTools,
	messages: Array,
	response: Dictionary
) -> bool:
	if not bool(response.get("ok", false)):
		job.append_log(str(response.get("error", "model request failed")))
		job.stage = AgenticStudioJob.STAGE_FAILED
		job.save()
		if tools.has_writes():
			await finish_job(job, tools)
		else:
			tools.discard_if_empty()
		return false

	var message: Dictionary = response.get("message", {})
	messages.append(AgenticStudioModelClient.assistant_message_for_history(message))
	var text: String = str(message.get("content", "")).strip_edges()
	var tool_calls: Array = message.get("tool_calls", [])
	# Log assistant prose only when it is not a content-emitted tool JSON.
	if not text.is_empty() and tool_calls.is_empty():
		job.append_log(text)
		job.save()
	elif not text.is_empty() and bool(message.get("from_content_tools", false)):
		job.append_log("Model requested tool(s) via content.")
		job.save()
	elif not text.is_empty():
		job.append_log(text)
		job.save()
	return true


static func _handle_one_tool(
	job: AgenticStudioJob,
	tools: AgenticStudioSceneTools,
	messages: Array,
	call: Dictionary,
	ask_writes: bool,
	ask_fn: Callable,
	from_content: bool
) -> Dictionary:
	var call_id: String = str(call.get("id", ""))
	var fn: Dictionary = call.get("function", {})
	var tool_name: String = str(fn.get("name", ""))
	var args: Dictionary = AgenticStudioModelClient.parse_tool_arguments(
		str(fn.get("arguments", "{}"))
	)

	var result_payload: Dictionary = {"ok": false, "error": "unhandled"}

	if not AgenticStudioSceneTools.is_allowed_tool(tool_name):
		var blocked: Dictionary = tools.execute(tool_name, args)
		job.append_log(str(blocked.get("log", AgenticStudioSceneTools.BLOCKED_MESSAGE)))
		job.save()
		result_payload = blocked.get(
			"result",
			{"ok": false, "error": AgenticStudioSceneTools.BLOCKED_MESSAGE}
		)
		if not from_content:
			messages.append(AgenticStudioModelClient.tool_result_message(call_id, result_payload))
		return result_payload

	var PolicyScript = preload("res://addons/agentic_studio/policy.gd")
	var needs_ask: bool = PolicyScript.should_ask(tool_name, args, ask_writes)
	if needs_ask:
		var allowed: bool = bool(ask_fn.call(tool_name, args))
		if not allowed:
			var skipped: Dictionary = tools.execute_skipped(tool_name, args)
			job.append_log(str(skipped.get("log", "skipped")))
			job.save()
			result_payload = skipped.get("result", {"ok": false, "error": "skipped by user"})
			if not from_content:
				messages.append(
					AgenticStudioModelClient.tool_result_message(call_id, result_payload)
				)
			return result_payload

	var outcome: Dictionary
	if tool_name == AgenticStudioSceneTools.TOOL_PLAY_SCENE:
		outcome = await tools.execute_play()
	elif tool_name == AgenticStudioSceneTools.TOOL_CREATE_ASSET:
		outcome = await tools.execute_create_asset(args)
	elif tool_name == AgenticStudioSceneTools.TOOL_SCREENSHOT:
		outcome = await tools.execute_screenshot(args)
	else:
		outcome = tools.execute(tool_name, args)
	job.append_log(str(outcome.get("log", "")))
	job.save()
	result_payload = outcome.get("result", {"ok": false})
	if not from_content:
		messages.append(AgenticStudioModelClient.tool_result_message(call_id, result_payload))
	return result_payload


static func finish_job(job: AgenticStudioJob, tools: AgenticStudioSceneTools) -> void:
	## After the model stops: if scene writes happened, play once and gate done/failed.
	## Page link writes join the undo action but do not trigger play.
	## Undo action stays committed so one editor undo still reverts the job.
	var SessionLogScript = preload("res://addons/agentic_studio/session_log.gd")
	if tools.has_scene_writes():
		var play_outcome: Dictionary = await tools.execute_play()
		job.append_log(str(play_outcome.get("log", "")))
		var play_result: Dictionary = play_outcome.get("result", {})
		var errs: Array = play_result.get("errors", [])
		if not bool(play_result.get("ok", false)) or not errs.is_empty():
			job.stage = AgenticStudioJob.STAGE_FAILED
		job.save()
	tools.finish()
	if job.stage != AgenticStudioJob.STAGE_FAILED:
		job.stage = AgenticStudioJob.STAGE_DONE
		job.save()
	else:
		job.save()
	SessionLogScript.append_plan_or_run(
		job.model_id,
		job.mode,
		tools.cited_page_ids,
		tools.ops_log,
		tools.last_play_result,
		AgenticStudioConfig.get_model(job.model_id)
	)


static func run_plan_sync(
	job: AgenticStudioJob,
	model: Dictionary,
	tools: AgenticStudioSceneTools
) -> void:
	## Plan may call list_pages / get_page / list_dir / read_file / screenshot only. No writes.
	var messages: Array = AgenticStudioModelClient.initial_plan_messages(job.prompt)
	var round_i: int = 0
	while round_i < AgenticStudioModelClient.MAX_TOOL_ROUNDS:
		AgenticStudioModelClient.apply_pending_shots(messages, model, tools)
		var response: Dictionary = AgenticStudioModelClient.request_chat_via_client(
			model,
			messages,
			true,
			AgenticStudioModelClient.DEFAULT_TIMEOUT_SEC,
			true
		)
		if not bool(response.get("ok", false)):
			job.append_log(str(response.get("error", "model request failed")))
			job.stage = AgenticStudioJob.STAGE_FAILED
			job.save()
			return

		var message: Dictionary = response.get("message", {})
		messages.append(AgenticStudioModelClient.assistant_message_for_history(message))
		var text: String = str(message.get("content", "")).strip_edges()
		var tool_calls: Array = message.get("tool_calls", [])
		if not text.is_empty() and tool_calls.is_empty():
			job.append_log(text)
			job.save()
		elif not text.is_empty() and bool(message.get("from_content_tools", false)):
			job.append_log("Model requested tool(s) via content.")
			job.save()
		elif not text.is_empty():
			job.append_log(text)
			job.save()

		if tool_calls.is_empty():
			break

		round_i += 1
		job.append_log("Tool round %d/%d (%d call(s))" % [
			round_i,
			AgenticStudioModelClient.MAX_TOOL_ROUNDS,
			tool_calls.size(),
		])
		job.save()

		var from_content: bool = bool(message.get("from_content_tools", false))
		var content_results: Array = []
		for call_v: Variant in tool_calls:
			if typeof(call_v) != TYPE_DICTIONARY:
				continue
			var result_payload: Dictionary = await _handle_one_plan_tool(
				job,
				tools,
				messages,
				call_v,
				from_content
			)
			if from_content:
				content_results.append(JSON.stringify(result_payload))

		if from_content and not content_results.is_empty():
			messages.append(AgenticStudioModelClient.tool_results_user_message(content_results))

		if round_i >= AgenticStudioModelClient.MAX_TOOL_ROUNDS:
			job.append_log(
				"Stopped after %d tool rounds." % AgenticStudioModelClient.MAX_TOOL_ROUNDS
			)
			job.save()
			break

	if job.stage != AgenticStudioJob.STAGE_FAILED:
		job.stage = AgenticStudioJob.STAGE_PLANNED
		job.save()
	var SessionLogScript = preload("res://addons/agentic_studio/session_log.gd")
	SessionLogScript.append_plan_or_run(
		job.model_id,
		job.mode,
		tools.cited_page_ids,
		tools.ops_log,
		null,
		AgenticStudioConfig.get_model(job.model_id)
	)


static func _handle_one_plan_tool(
	job: AgenticStudioJob,
	tools: AgenticStudioSceneTools,
	messages: Array,
	call: Dictionary,
	from_content: bool
) -> Dictionary:
	var call_id: String = str(call.get("id", ""))
	var fn: Dictionary = call.get("function", {})
	var tool_name: String = str(fn.get("name", ""))
	var args: Dictionary = AgenticStudioModelClient.parse_tool_arguments(
		str(fn.get("arguments", "{}"))
	)
	var result_payload: Dictionary = {"ok": false, "error": "unhandled"}

	if not AgenticStudioSceneTools.is_plan_tool(tool_name):
		job.append_log("Plan blocked tool: %s" % tool_name)
		job.save()
		result_payload = {"ok": false, "error": AgenticStudioSceneTools.BLOCKED_MESSAGE}
		if not from_content:
			messages.append(AgenticStudioModelClient.tool_result_message(call_id, result_payload))
		return result_payload

	var outcome: Dictionary
	if tool_name == AgenticStudioSceneTools.TOOL_SCREENSHOT:
		outcome = await tools.execute_screenshot(args)
	else:
		outcome = tools.execute(tool_name, args)
	job.append_log(str(outcome.get("log", "")))
	job.save()
	result_payload = outcome.get("result", {"ok": false})
	if not from_content:
		messages.append(AgenticStudioModelClient.tool_result_message(call_id, result_payload))
	return result_payload
