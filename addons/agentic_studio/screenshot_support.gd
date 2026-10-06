class_name AgenticStudioScreenshotSupport
extends RefCounted
## Capture editor / play viewports to user://agentic_studio/logs/shots/<session>/.

const TARGET_EDITOR_2D: String = "editor_2d"
const TARGET_EDITOR_3D: String = "editor_3d"
const TARGET_PLAY: String = "play"
const MAX_SHOTS_PER_SESSION: int = 5
const SHOTS_SUBDIR: String = "shots"


static func shots_root() -> String:
	return AgenticStudioConfig.LOGS_DIR.path_join(SHOTS_SUBDIR)


static func session_shots_dir(session_id: String) -> String:
	var sid: String = session_id.strip_edges()
	if sid.is_empty():
		sid = "session"
	sid = sid.replace("/", "_").replace("\\", "_").replace("..", "_")
	return shots_root().path_join(sid)


static func ensure_session_dir(session_id: String) -> String:
	AgenticStudioConfig.ensure_dirs()
	var dir_path: String = session_shots_dir(session_id)
	var abs_dir: String = ProjectSettings.globalize_path(dir_path)
	if not DirAccess.dir_exists_absolute(abs_dir):
		DirAccess.make_dir_recursive_absolute(abs_dir)
	return dir_path


static func normalize_target(raw: String) -> String:
	var t: String = raw.strip_edges().to_lower().replace("-", "_")
	match t:
		"editor_2d", "2d", "viewport_2d":
			return TARGET_EDITOR_2D
		"editor_3d", "3d", "viewport", "viewport_3d":
			return TARGET_EDITOR_3D
		"play", "game", "running":
			return TARGET_PLAY
		_:
			return ""


static func is_valid_target(target: String) -> bool:
	return not normalize_target(target).is_empty()


func capture(session_id: String, target_raw: String) -> Dictionary:
	## Async: await editor process frames before reading viewport textures.
	## Returns {ok, error, path, target, pruned:PackedStringArray, log}.
	var target: String = normalize_target(target_raw)
	if target.is_empty():
		return {
			"ok": false,
			"error": "target must be editor_2d, editor_3d, or play",
			"path": "",
			"target": target_raw,
			"pruned": PackedStringArray(),
			"log": "screenshot failed: bad target",
		}

	var img: Image = null
	var err_msg: String = ""
	match target:
		TARGET_EDITOR_2D:
			var r2: Dictionary = await _capture_editor_2d()
			img = r2.get("image") as Image
			err_msg = str(r2.get("error", ""))
		TARGET_EDITOR_3D:
			var r3: Dictionary = await _capture_editor_3d()
			img = r3.get("image") as Image
			err_msg = str(r3.get("error", ""))
		TARGET_PLAY:
			var rp: Dictionary = await _capture_play()
			img = rp.get("image") as Image
			err_msg = str(rp.get("error", ""))

	if img == null or img.get_width() < 1 or img.get_height() < 1:
		var fail: String = err_msg if not err_msg.is_empty() else "empty capture"
		return {
			"ok": false,
			"error": fail,
			"path": "",
			"target": target,
			"pruned": PackedStringArray(),
			"log": "screenshot failed target=%s: %s" % [target, fail],
		}

	var dir_path: String = ensure_session_dir(session_id)
	var file_name: String = "shot_%d_%s.png" % [Time.get_unix_time_from_system(), target]
	var res_path: String = dir_path.path_join(file_name)
	var abs_path: String = ProjectSettings.globalize_path(res_path)
	var save_err: Error = img.save_png(abs_path)
	if save_err != OK:
		return {
			"ok": false,
			"error": "could not save PNG (%d)" % save_err,
			"path": "",
			"target": target,
			"pruned": PackedStringArray(),
			"log": "screenshot failed: save error %d" % save_err,
		}

	var pruned: PackedStringArray = prune_session_shots(session_id)
	return {
		"ok": true,
		"error": "",
		"path": res_path,
		"target": target,
		"pruned": pruned,
		"log": "screenshot ok target=%s path=%s" % [target, res_path],
	}


func _await_editor_frames(count: int = 2) -> void:
	## Prefer SceneTree.process_frame over RenderingServer.frame_post_draw.
	## After a sync HTTP poll the editor may not redraw, so frame_post_draw can stall forever.
	var base: Control = EditorInterface.get_base_control()
	if base == null:
		return
	var tree: SceneTree = base.get_tree()
	if tree == null:
		return
	for _i: int in range(maxi(1, count)):
		await tree.process_frame


func _capture_editor_3d() -> Dictionary:
	var vp: SubViewport = EditorInterface.get_editor_viewport_3d(0)
	if vp == null:
		return {"image": null, "error": "no 3D editor viewport"}
	await _await_editor_frames(2)
	var tex: ViewportTexture = vp.get_texture()
	if tex == null:
		return {"image": null, "error": "3D viewport has no texture"}
	var img: Image = tex.get_image()
	if img == null:
		return {"image": null, "error": "3D viewport image was null"}
	return {"image": img, "error": ""}


func _capture_editor_2d() -> Dictionary:
	var vp: SubViewport = EditorInterface.get_editor_viewport_2d()
	if vp == null:
		return {"image": null, "error": "no 2D editor viewport"}
	await _await_editor_frames(2)
	var tex: ViewportTexture = vp.get_texture()
	if tex == null:
		return {"image": null, "error": "2D viewport has no texture"}
	var img: Image = tex.get_image()
	if img == null:
		return {"image": null, "error": "2D viewport image was null"}
	return {"image": img, "error": ""}


func _capture_play() -> Dictionary:
	## Uses the running game window. Does not start a second play.
	if not EditorInterface.is_playing_scene():
		return {
			"image": null,
			"error": "no play running — use play_scene first or screenshot editor_3d",
		}
	await _await_editor_frames(2)
	var img: Image = _image_from_other_windows()
	if img != null:
		return {"image": img, "error": ""}
	# Embedded game: try screen region of the main window as a last resort is wrong;
	# prefer failing clearly over capturing the editor.
	return {
		"image": null,
		"error": "could not capture play window (is the game window available?)",
	}


func _image_from_other_windows() -> Image:
	var editor_id: int = DisplayServer.MAIN_WINDOW_ID
	var ids: PackedInt32Array = DisplayServer.get_window_list()
	for id: int in ids:
		if id == editor_id:
			continue
		var size: Vector2i = DisplayServer.window_get_size(id)
		if size.x < 4 or size.y < 4:
			continue
		var pos: Vector2i = DisplayServer.window_get_position(id)
		if DisplayServer.has_feature(DisplayServer.FEATURE_SCREEN_CAPTURE):
			var shot: Image = DisplayServer.screen_get_image_rect(Rect2i(pos, size))
			if shot != null and shot.get_width() > 0:
				return shot
	return null


static func list_session_pngs(session_id: String) -> PackedStringArray:
	var dir_path: String = session_shots_dir(session_id)
	var abs_dir: String = ProjectSettings.globalize_path(dir_path)
	var out: PackedStringArray = PackedStringArray()
	if not DirAccess.dir_exists_absolute(abs_dir):
		return out
	var da: DirAccess = DirAccess.open(dir_path)
	if da == null:
		return out
	da.list_dir_begin()
	var name: String = da.get_next()
	while name != "":
		if not da.current_is_dir() and name.ends_with(".png"):
			out.append(dir_path.path_join(name))
		name = da.get_next()
	da.list_dir_end()
	# Newest last by filename (timestamp prefix).
	out.sort()
	return out


static func prune_session_shots(session_id: String) -> PackedStringArray:
	## Keep the 5 newest PNGs. Returns paths that were deleted.
	var pruned: PackedStringArray = PackedStringArray()
	var files: PackedStringArray = list_session_pngs(session_id)
	while files.size() > MAX_SHOTS_PER_SESSION:
		var oldest: String = files[0]
		files.remove_at(0)
		var abs_oldest: String = ProjectSettings.globalize_path(oldest)
		if FileAccess.file_exists(abs_oldest):
			DirAccess.remove_absolute(abs_oldest)
			pruned.append(oldest)
	return pruned


static func delete_shot_file(path: String) -> bool:
	var p: String = path.strip_edges()
	if p.is_empty():
		return false
	# Only allow under our shots root.
	var root: String = shots_root()
	if not p.begins_with(root) and not p.begins_with(ProjectSettings.globalize_path(root)):
		# Also accept res-style user path.
		if not p.begins_with("user://agentic_studio/logs/shots"):
			return false
	var abs_path: String = ProjectSettings.globalize_path(p) if p.begins_with("user://") else p
	if FileAccess.file_exists(abs_path):
		return DirAccess.remove_absolute(abs_path) == OK
	return false


static func delete_session_shots_dir(session_id: String) -> void:
	var dir_path: String = session_shots_dir(session_id)
	var abs_dir: String = ProjectSettings.globalize_path(dir_path)
	if not DirAccess.dir_exists_absolute(abs_dir):
		return
	_remove_dir_recursive(abs_dir)


static func _remove_dir_recursive(abs_dir: String) -> void:
	var da: DirAccess = DirAccess.open(abs_dir)
	if da == null:
		return
	da.list_dir_begin()
	var name: String = da.get_next()
	while name != "":
		if name == "." or name == "..":
			name = da.get_next()
			continue
		var child: String = abs_dir.path_join(name)
		if da.current_is_dir():
			_remove_dir_recursive(child)
		else:
			DirAccess.remove_absolute(child)
		name = da.get_next()
	da.list_dir_end()
	DirAccess.remove_absolute(abs_dir)


static func file_to_data_url(path: String) -> String:
	var abs_path: String = ProjectSettings.globalize_path(path) if path.begins_with("user://") else path
	if not FileAccess.file_exists(abs_path):
		return ""
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(abs_path)
	if bytes.is_empty():
		return ""
	return "data:image/png;base64,%s" % Marshalls.raw_to_base64(bytes)
