class_name AgenticStudioPlayDebugger
extends EditorDebuggerPlugin
## Latches EditorDebuggerSession.stopped for the play sensor. No Output-panel scraping.

signal session_stopped

var _armed: bool = false
var _stopped: bool = false
var _session_ids: PackedInt32Array = PackedInt32Array()


func arm() -> void:
	_armed = true
	_stopped = false


func disarm() -> void:
	_armed = false


func consume_stopped() -> bool:
	## True if a session stopped while armed since the last arm/consume.
	var was: bool = _stopped
	_stopped = false
	return was


func has_stopped() -> bool:
	return _stopped


func _setup_session(session_id: int) -> void:
	var session: EditorDebuggerSession = get_session(session_id)
	if session == null:
		return
	if not _session_ids.has(session_id):
		_session_ids.append(session_id)
	if not session.stopped.is_connected(_on_session_stopped):
		session.stopped.connect(_on_session_stopped)
	if not session.started.is_connected(_on_session_started):
		session.started.connect(_on_session_started)


func _on_session_started() -> void:
	pass


func _on_session_stopped() -> void:
	if not _armed:
		return
	_stopped = true
	session_stopped.emit()


func _has_capture(capture: String) -> bool:
	return capture == "agentic_studio_play"


func _capture(message: String, data: Array, session_id: int) -> bool:
	# Reserved for future probe messages; latching uses session.stopped.
	return false
