class_name AgenticStudioFileSupport
extends RefCounted
## Text file helpers under res:// for list/read/write/delete tools.
## Undo methods are called from EditorUndoRedoManager; keep this instance alive.

static func _string_has_nul(content: String) -> bool:
	## True when content contains a NUL byte. Do not put a NUL escape in source (U+FFFD parse noise).
	return content.to_utf8_buffer().find(0) >= 0


static func _binary_extensions() -> PackedStringArray:
	return PackedStringArray([
		"png", "jpg", "jpeg", "webp", "gif", "bmp", "svg", "ico",
		"glb", "gltf", "obj", "fbx", "dae", "blend",
		"wav", "ogg", "mp3", "import", "uid",
		"ttf", "otf", "woff", "woff2",
		"dll", "dylib", "so", "exe", "bin", "pck", "zip",
	])


static func _delete_extensions() -> PackedStringArray:
	return PackedStringArray([
		"gd", "tscn", "tres", "gdshader", "shader",
	])


static func normalize_res_path(path: String) -> Dictionary:
	## Returns {ok, path, error}. Path is a cleaned res://… form with no .. segments.
	path = path.strip_edges().replace("\\", "/")
	if path.is_empty():
		return {"ok": false, "path": "", "error": "path required"}
	if path.begins_with("user://"):
		return {"ok": false, "path": "", "error": "refusing user:// path"}
	if path.begins_with("file://"):
		return {"ok": false, "path": "", "error": "refusing file:// path"}
	if not path.begins_with("res://"):
		if path.begins_with("/"):
			return {"ok": false, "path": "", "error": "absolute paths outside res:// are refused"}
		path = "res://" + path.lstrip("/")
	var rest: String = path.substr(6)  # after res://
	var parts: PackedStringArray = rest.split("/", false)
	var cleaned: PackedStringArray = PackedStringArray()
	for part: String in parts:
		if part.is_empty() or part == ".":
			continue
		if part == "..":
			return {"ok": false, "path": "", "error": "path must stay under res://"}
		cleaned.append(part)
	var out: String = "res://"
	if cleaned.size() > 0:
		out = "res://" + "/".join(cleaned)
	return {"ok": true, "path": out, "error": ""}


static func is_probably_binary(path: String) -> bool:
	var ext: String = path.get_extension().to_lower()
	return _binary_extensions().has(ext)


static func is_deletable_kind(path: String) -> bool:
	## Pages (.tres), scenes (.tscn), scripts (.gd / shaders).
	var ext: String = path.get_extension().to_lower()
	return _delete_extensions().has(ext)


static func list_dir(path: String) -> Dictionary:
	var norm: Dictionary = normalize_res_path(path if not path.strip_edges().is_empty() else "res://")
	if not bool(norm.get("ok", false)):
		return {"ok": false, "error": str(norm.get("error", "bad path")), "entries": []}
	var dir_path: String = str(norm["path"])
	if dir_path != "res://" and not dir_path.ends_with("/"):
		# If it points at a file, list its parent.
		if FileAccess.file_exists(dir_path):
			dir_path = dir_path.get_base_dir()
	var abs_dir: String = ProjectSettings.globalize_path(dir_path)
	if not DirAccess.dir_exists_absolute(abs_dir):
		return {"ok": false, "error": "directory not found: %s" % dir_path, "entries": []}
	var da: DirAccess = DirAccess.open(dir_path)
	if da == null:
		return {"ok": false, "error": "could not open %s" % dir_path, "entries": []}
	var entries: Array = []
	da.list_dir_begin()
	var name: String = da.get_next()
	while name != "":
		if name == "." or name == ".." or name.begins_with("._"):
			name = da.get_next()
			continue
		var child: String = dir_path.rstrip("/") + "/" + name
		if dir_path == "res://":
			child = "res://" + name
		var is_dir: bool = da.current_is_dir()
		entries.append({
			"name": name,
			"path": child,
			"is_dir": is_dir,
		})
		name = da.get_next()
	da.list_dir_end()
	entries.sort_custom(func(a: Variant, b: Variant) -> bool:
		return str((a as Dictionary).get("name", "")) < str((b as Dictionary).get("name", ""))
	)
	return {"ok": true, "error": "", "path": dir_path, "entries": entries}


static func read_text_file(path: String) -> Dictionary:
	var norm: Dictionary = normalize_res_path(path)
	if not bool(norm.get("ok", false)):
		return {"ok": false, "error": str(norm.get("error", "bad path")), "content": "", "path": ""}
	var res_path: String = str(norm["path"])
	if is_probably_binary(res_path):
		return {"ok": false, "error": "refusing binary file: %s" % res_path, "content": "", "path": res_path}
	if not FileAccess.file_exists(res_path):
		return {"ok": false, "error": "file not found: %s" % res_path, "content": "", "path": res_path}
	var f: FileAccess = FileAccess.open(res_path, FileAccess.READ)
	if f == null:
		return {
			"ok": false,
			"error": "could not open %s (%d)" % [res_path, FileAccess.get_open_error()],
			"content": "",
			"path": res_path,
		}
	var content: String = f.get_as_text()
	f.close()
	# Reject NUL-heavy payloads that slipped past extension checks.
	# Do not embed a NUL escape in source — Godot's UTF-8 parse warns U+FFFD on literal NULs.
	if _string_has_nul(content):
		return {"ok": false, "error": "refusing binary content: %s" % res_path, "content": "", "path": res_path}
	return {"ok": true, "error": "", "content": content, "path": res_path}


static func write_text_file(path: String, content: String) -> Dictionary:
	## Creates or replaces a text file. Returns previous content for undo.
	var norm: Dictionary = normalize_res_path(path)
	if not bool(norm.get("ok", false)):
		return {"ok": false, "error": str(norm.get("error", "bad path")), "path": ""}
	var res_path: String = str(norm["path"])
	if res_path == "res://" or res_path.ends_with("/"):
		return {"ok": false, "error": "path must be a file", "path": res_path}
	if is_probably_binary(res_path):
		return {"ok": false, "error": "refusing binary file: %s" % res_path, "path": res_path}
	if typeof(content) != TYPE_STRING:
		content = str(content)
	if _string_has_nul(content):
		return {"ok": false, "error": "refusing binary content", "path": res_path}

	var existed: bool = FileAccess.file_exists(res_path)
	var previous: String = ""
	if existed:
		var prev_read: Dictionary = read_text_file(res_path)
		if not bool(prev_read.get("ok", false)):
			return {
				"ok": false,
				"error": "could not read existing file for undo: %s" % str(prev_read.get("error", "")),
				"path": res_path,
			}
		previous = str(prev_read.get("content", ""))

	var parent: String = res_path.get_base_dir()
	if not parent.is_empty() and parent != "res://":
		var abs_parent: String = ProjectSettings.globalize_path(parent)
		if not DirAccess.dir_exists_absolute(abs_parent):
			var mk: Error = DirAccess.make_dir_recursive_absolute(abs_parent)
			if mk != OK:
				return {"ok": false, "error": "could not create directory %s (%d)" % [parent, mk], "path": res_path}

	var f: FileAccess = FileAccess.open(res_path, FileAccess.WRITE)
	if f == null:
		return {
			"ok": false,
			"error": "could not write %s (%d)" % [res_path, FileAccess.get_open_error()],
			"path": res_path,
		}
	f.store_string(content)
	f.close()
	return {
		"ok": true,
		"error": "",
		"path": res_path,
		"existed": existed,
		"previous": previous,
		"created": not existed,
	}


static func is_protected_user_path(path: String) -> bool:
	## Config and session logs under user:// must never be deleted by tools.
	var p: String = path.strip_edges().replace("\\", "/")
	if p.begins_with("user://agentic_studio.cfg"):
		return true
	if p.begins_with("user://agentic_studio/logs") or p.begins_with("user://agentic_studio/logs/"):
		return true
	# Globalized form of the logs dir (editor userdata).
	var logs_abs: String = ProjectSettings.globalize_path(AgenticStudioConfig.LOGS_DIR).replace("\\", "/")
	var cfg_abs: String = ProjectSettings.globalize_path(AgenticStudioConfig.CONFIG_PATH).replace("\\", "/")
	var abs_p: String = p
	if p.begins_with("user://") or p.begins_with("res://"):
		abs_p = ProjectSettings.globalize_path(p).replace("\\", "/")
	if abs_p == cfg_abs or abs_p.begins_with(logs_abs.rstrip("/")):
		return true
	return false


static func delete_text_file(path: String) -> Dictionary:
	## Deletes a page/scene/script under res://. Never user:// config or logs.
	var raw: String = path.strip_edges()
	if is_protected_user_path(raw):
		return {
			"ok": false,
			"error": "refusing user:// config or agentic_studio/logs path",
			"path": raw,
		}
	if raw.begins_with("user://"):
		return {"ok": false, "error": "refusing user:// path", "path": raw}
	var norm: Dictionary = normalize_res_path(path)
	if not bool(norm.get("ok", false)):
		return {"ok": false, "error": str(norm.get("error", "bad path")), "path": ""}
	var res_path: String = str(norm["path"])
	if res_path.begins_with("user://") or is_protected_user_path(res_path):
		return {"ok": false, "error": "refusing user:// path", "path": res_path}
	if not is_deletable_kind(res_path):
		return {
			"ok": false,
			"error": "delete_file only allows .gd, .tscn, .tres, or shader paths",
			"path": res_path,
		}
	if not FileAccess.file_exists(res_path):
		return {"ok": false, "error": "file not found: %s" % res_path, "path": res_path}
	var prev_read: Dictionary = read_text_file(res_path)
	var previous: String = ""
	if bool(prev_read.get("ok", false)):
		previous = str(prev_read.get("content", ""))
	else:
		# Fall back to raw bytes as latin1-ish text for undo of non-UTF quirks.
		var rf: FileAccess = FileAccess.open(res_path, FileAccess.READ)
		if rf != null:
			previous = rf.get_as_text()
			rf.close()

	var abs_path: String = ProjectSettings.globalize_path(res_path)
	var err: Error = DirAccess.remove_absolute(abs_path)
	if err != OK:
		return {"ok": false, "error": "could not delete %s (%d)" % [res_path, err], "path": res_path}
	# Sidecar .uid if present.
	var uid_path: String = res_path + ".uid"
	var uid_abs: String = ProjectSettings.globalize_path(uid_path)
	if FileAccess.file_exists(uid_abs):
		DirAccess.remove_absolute(uid_abs)
	return {
		"ok": true,
		"error": "",
		"path": res_path,
		"previous": previous,
		"existed": true,
	}


static func triggers_play_gate(path: String) -> bool:
	var ext: String = path.get_extension().to_lower()
	return ext == "gd" or ext == "tscn" or ext == "gdshader" or ext == "shader"


## --- Instance methods for UndoRedo do/undo ---

func apply_write(path: String, content: String) -> void:
	write_text_file(path, content)


func undo_write(path: String, previous: String, existed: bool) -> void:
	if existed:
		write_text_file(path, previous)
	else:
		var abs_path: String = ProjectSettings.globalize_path(path)
		if FileAccess.file_exists(abs_path):
			DirAccess.remove_absolute(abs_path)
		var uid_abs: String = ProjectSettings.globalize_path(path + ".uid")
		if FileAccess.file_exists(uid_abs):
			DirAccess.remove_absolute(uid_abs)


func apply_delete(path: String) -> void:
	delete_text_file(path)


func undo_delete(path: String, previous: String) -> void:
	write_text_file(path, previous)
