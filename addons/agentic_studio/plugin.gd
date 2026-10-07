@tool
extends EditorPlugin
## AgenticStudio editor plugin — dock, Plan, Run, and Auto-approve.

const DockScript = preload("res://addons/agentic_studio/dock.gd")
const ConfigScript = preload("res://addons/agentic_studio/config.gd")
const LiveExecuteScript = preload("res://addons/agentic_studio/live_execute_check.gd")
const LivePagesScript = preload("res://addons/agentic_studio/live_pages_check.gd")
const LiveAssetScript = preload("res://addons/agentic_studio/live_asset_check.gd")
const LiveDockScript = preload("res://addons/agentic_studio/live_dock_check.gd")
const LiveFileScript = preload("res://addons/agentic_studio/live_file_check.gd")
const LiveScreenshotScript = preload("res://addons/agentic_studio/live_screenshot_check.gd")
const LivePlaySensorScript = preload("res://addons/agentic_studio/live_play_sensor_check.gd")
const LiveSidecarRunScript = preload("res://addons/agentic_studio/live_sidecar_run_check.gd")
const LiveEditorOpsScript = preload("res://addons/agentic_studio/live_editor_ops_check.gd")
const PageStoreScript = preload("res://addons/agentic_studio/page_store.gd")
const PlayDebuggerScript = preload("res://addons/agentic_studio/play_debugger.gd")
const PlaySupportScript = preload("res://addons/agentic_studio/play_support.gd")
const ApplyServerScript = preload("res://addons/agentic_studio/apply_server.gd")
const SessionLogScript = preload("res://addons/agentic_studio/session_log.gd")

var _dock: Control
var _play_debugger: EditorDebuggerPlugin
var _apply_server: Node


func _enter_tree() -> void:
	ConfigScript.ensure_dirs()
	PageStoreScript.ensure_dirs()
	SessionLogScript.ensure_dirs()
	_play_debugger = PlayDebuggerScript.new()
	add_debugger_plugin(_play_debugger)
	PlaySupportScript.set_play_debugger(_play_debugger)
	_apply_server = ApplyServerScript.new()
	_apply_server.name = "AgenticStudioApplyServer"
	add_child(_apply_server)
	_apply_server.start()
	_dock = DockScript.new()
	_dock.name = "AgenticStudio"
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)
	print("AgenticStudio: plugin enabled")
	if OS.get_environment("AGENTIC_STUDIO_LIVE_EXECUTE") == "1":
		call_deferred("_run_live_execute_and_quit")
	elif OS.get_environment("AGENTIC_STUDIO_LIVE_PAGES") == "1":
		call_deferred("_run_live_pages_and_quit")
	elif OS.get_environment("AGENTIC_STUDIO_LIVE_ASSET") == "1":
		call_deferred("_run_live_asset_and_quit")
	elif OS.get_environment("AGENTIC_STUDIO_LIVE_DOCK") == "1":
		call_deferred("_run_live_dock_and_quit")
	elif OS.get_environment("AGENTIC_STUDIO_LIVE_FILE") == "1":
		call_deferred("_run_live_file_and_quit")
	elif OS.get_environment("AGENTIC_STUDIO_LIVE_SCREENSHOT") == "1":
		call_deferred("_run_live_screenshot_and_quit")
	elif OS.get_environment("AGENTIC_STUDIO_LIVE_PLAY_SENSOR") == "1":
		call_deferred("_run_live_play_sensor_and_quit")
	elif OS.get_environment("AGENTIC_STUDIO_LIVE_EDITOR_OPS") == "1":
		call_deferred("_run_live_editor_ops_and_quit")


func _exit_tree() -> void:
	PlaySupportScript.set_play_debugger(null)
	if _play_debugger != null:
		remove_debugger_plugin(_play_debugger)
		_play_debugger = null
	if _apply_server != null:
		_apply_server.stop()
		_apply_server.queue_free()
		_apply_server = null
	if _dock != null:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null
	print("AgenticStudio: plugin disabled")


func _run_live_execute_and_quit() -> void:
	# Wait for the editor dock and filesystem to settle.
	await get_tree().create_timer(0.5).timeout
	var check = LiveExecuteScript.new()
	var result: Dictionary = await check.run()
	if bool(result.get("ok", false)):
		print("AgenticStudio live_execute_check: OK")
		for key: String in ["auto_job", "broken_job", "run_job", "plan_job"]:
			if result.has(key):
				print("  ", key, "=", result[key])
		get_tree().quit(0)
	else:
		print("AgenticStudio live_execute_check: FAILED")
		var failures: PackedStringArray = result.get("failures", PackedStringArray())
		for f: String in failures:
			print("  - ", f)
		get_tree().quit(1)


func _run_live_pages_and_quit() -> void:
	await get_tree().create_timer(0.5).timeout
	var check = LivePagesScript.new()
	var result: Dictionary = await check.run()
	if bool(result.get("ok", false)):
		print("AgenticStudio live_pages_check: OK")
		for key: String in ["page_path", "plan_job"]:
			if result.has(key):
				print("  ", key, "=", result[key])
		get_tree().quit(0)
	else:
		print("AgenticStudio live_pages_check: FAILED")
		var failures: PackedStringArray = result.get("failures", PackedStringArray())
		for f: String in failures:
			print("  - ", f)
		get_tree().quit(1)


func _run_live_asset_and_quit() -> void:
	await get_tree().create_timer(0.5).timeout
	var check = LiveAssetScript.new()
	var result: Dictionary = await check.run()
	if bool(result.get("ok", false)):
		print("AgenticStudio live_asset_check: OK")
		for key: String in ["asset_job", "plan_job", "asset_path"]:
			if result.has(key):
				print("  ", key, "=", result[key])
		get_tree().quit(0)
	else:
		print("AgenticStudio live_asset_check: FAILED")
		var failures: PackedStringArray = result.get("failures", PackedStringArray())
		for f: String in failures:
			print("  - ", f)
		get_tree().quit(1)


func _run_live_dock_and_quit() -> void:
	await get_tree().create_timer(0.5).timeout
	var check = LiveDockScript.new()
	var result: Dictionary = await check.run()
	if bool(result.get("ok", false)):
		print("AgenticStudio live_dock_check: OK")
		get_tree().quit(0)
	else:
		print("AgenticStudio live_dock_check: FAILED")
		var failures: PackedStringArray = result.get("failures", PackedStringArray())
		for f: String in failures:
			print("  - ", f)
		get_tree().quit(1)


func _run_live_file_and_quit() -> void:
	await get_tree().create_timer(0.5).timeout
	var check = LiveFileScript.new()
	var result: Dictionary = await check.run()
	if bool(result.get("ok", false)):
		print("AgenticStudio live_file_check: OK")
		for key: String in ["auto_job", "del_job", "plan_job"]:
			if result.has(key):
				print("  ", key, "=", result[key])
		get_tree().quit(0)
	else:
		print("AgenticStudio live_file_check: FAILED")
		var failures: PackedStringArray = result.get("failures", PackedStringArray())
		for f: String in failures:
			print("  - ", f)
		get_tree().quit(1)


func _run_live_screenshot_and_quit() -> void:
	await get_tree().create_timer(0.5).timeout
	var check = LiveScreenshotScript.new()
	var result: Dictionary = await check.run()
	if bool(result.get("ok", false)):
		print("AgenticStudio live_screenshot_check: OK")
		for key: String in ["auto_job", "plan_job"]:
			if result.has(key):
				print("  ", key, "=", result[key])
		get_tree().quit(0)
	else:
		print("AgenticStudio live_screenshot_check: FAILED")
		var failures: PackedStringArray = result.get("failures", PackedStringArray())
		for f: String in failures:
			print("  - ", f)
		get_tree().quit(1)


func _run_live_play_sensor_and_quit() -> void:
	# Give the editor (docks/menus/filesystem) time to finish main-thread setup on macOS.
	await get_tree().create_timer(2.0).timeout
	var check = LivePlaySensorScript.new()
	var result: Dictionary = await check.run()
	if not bool(result.get("ok", false)):
		print("AgenticStudio live_play_sensor_check: FAILED")
		var failures: PackedStringArray = result.get("failures", PackedStringArray())
		for f: String in failures:
			print("  - ", f)
		get_tree().quit(1)
		return
	print("AgenticStudio live_play_sensor_check: OK")
	for key: String in ["auto_job", "parse_job", "plan_job"]:
		if result.has(key):
			print("  ", key, "=", result[key])
	# Close the harness loop under the same live env.
	var harness = LiveSidecarRunScript.new()
	var harness_result: Dictionary = await harness.run()
	if bool(harness_result.get("ok", false)):
		print("AgenticStudio live_sidecar_run_check: OK")
		get_tree().quit(0)
	else:
		print("AgenticStudio live_sidecar_run_check: FAILED")
		var hf: PackedStringArray = harness_result.get("failures", PackedStringArray())
		for f2: String in hf:
			print("  - ", f2)
		get_tree().quit(1)


func _run_live_editor_ops_and_quit() -> void:
	await get_tree().create_timer(2.0).timeout
	var check = LiveEditorOpsScript.new()
	var result: Dictionary = await check.run()
	if bool(result.get("ok", false)):
		print("AgenticStudio live_editor_ops_check: OK")
		get_tree().quit(0)
	else:
		print("AgenticStudio live_editor_ops_check: FAILED")
		var failures: PackedStringArray = result.get("failures", PackedStringArray())
		for f: String in failures:
			print("  - ", f)
		get_tree().quit(1)
