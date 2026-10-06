extends Node
## Temporary autoload for the play gate only. Not a permanent project autoload.
## Waits two process frames, writes user://agentic/last_frame.png and last_play.json, then quits.

const AGENTIC_DIR: String = "user://agentic"
const FRAME_PATH: String = "user://agentic/last_frame.png"
const PLAY_JSON_PATH: String = "user://agentic/last_play.json"


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	await get_tree().process_frame
	await get_tree().process_frame

	_ensure_agentic_dir()
	var frame_ok: bool = _write_frame()
	var errors: Array = []
	var ok: bool = frame_ok
	_write_play_json(ok, errors, frame_ok)
	# Quit so the editor debugger session emits stopped.
	get_tree().quit()


func _ensure_agentic_dir() -> void:
	var abs_dir: String = ProjectSettings.globalize_path(AGENTIC_DIR)
	if not DirAccess.dir_exists_absolute(abs_dir):
		DirAccess.make_dir_recursive_absolute(abs_dir)


func _write_frame() -> bool:
	var vp: Viewport = get_viewport()
	if vp == null:
		return false
	var tex: ViewportTexture = vp.get_texture()
	if tex == null:
		return false
	var img: Image = tex.get_image()
	if img == null or img.get_width() < 1 or img.get_height() < 1:
		return false
	var abs_path: String = ProjectSettings.globalize_path(FRAME_PATH)
	return img.save_png(abs_path) == OK


func _write_play_json(ok: bool, errors: Array, frame_ok: bool) -> void:
	var payload: Dictionary = {
		"ok": ok,
		"phase": "play",
		"errors": errors,
		"frame": FRAME_PATH if frame_ok else "",
		"probe": "PlayProbe",
		"frames_waited": 2,
	}
	var abs_path: String = ProjectSettings.globalize_path(PLAY_JSON_PATH)
	var f: FileAccess = FileAccess.open(abs_path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(payload))
	f.close()
