class_name AgenticStudioPageStore
extends RefCounted
## Save/load character and asset pages under res://studio/.

const PageScript = preload("res://addons/agentic_studio/page.gd")

const STUDIO_ROOT: String = "res://studio"
const CHARACTERS_DIR: String = "res://studio/characters"
const ASSETS_DIR: String = "res://studio/assets"


static func ensure_dirs() -> void:
	_ensure_dir(STUDIO_ROOT)
	_ensure_dir(CHARACTERS_DIR)
	_ensure_dir(ASSETS_DIR)


static func _ensure_dir(path: String) -> void:
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(path)):
		return
	var err: Error = DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path))
	if err != OK:
		push_warning("AgenticStudio: could not create %s (%d)" % [path, err])


static func dir_for_kind(kind: String) -> String:
	if kind == PageScript.KIND_ASSET:
		return ASSETS_DIR
	return CHARACTERS_DIR


static func slugify(title: String) -> String:
	var s: String = title.strip_edges().to_lower()
	var out: String = ""
	for i: int in range(s.length()):
		var ch: String = s[i]
		var code: int = ch.unicode_at(0)
		var is_alnum: bool = (
			(code >= 97 and code <= 122)
			or (code >= 48 and code <= 57)
		)
		if is_alnum:
			out += ch
		elif ch == " " or ch == "-" or ch == "_":
			if out.is_empty() or out[out.length() - 1] != "_":
				out += "_"
	out = out.strip_edges().trim_prefix("_").trim_suffix("_")
	if out.is_empty():
		out = "page"
	return out


static func path_for_title(kind: String, title: String) -> String:
	return "%s/%s.tres" % [dir_for_kind(kind), slugify(title)]


static func list_pages() -> Array:
	ensure_dirs()
	var out: Array = []
	_list_dir(CHARACTERS_DIR, PageScript.KIND_CHARACTER, out)
	_list_dir(ASSETS_DIR, PageScript.KIND_ASSET, out)
	return out


static func _list_dir(dir_path: String, kind: String, out: Array) -> void:
	var abs_dir: String = ProjectSettings.globalize_path(dir_path)
	if not DirAccess.dir_exists_absolute(abs_dir):
		return
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name: String = dir.get_next()
	while name != "":
		if (
			not dir.current_is_dir()
			and name.ends_with(".tres")
			and not name.begins_with("._")
		):
			var path: String = "%s/%s" % [dir_path, name]
			var page: Resource = load(path)
			var title: String = name.trim_suffix(".tres")
			if page != null:
				var loaded_title: String = str(page.get("title")).strip_edges()
				if not loaded_title.is_empty():
					title = loaded_title
			out.append({
				"title": title,
				"kind": kind,
				"path": path,
			})
		name = dir.get_next()
	dir.list_dir_end()


static func load_page(path: String) -> Resource:
	path = path.strip_edges()
	if path.is_empty():
		return null
	if not ResourceLoader.exists(path) and not FileAccess.file_exists(path):
		return null
	var res: Resource = load(path)
	if res == null:
		return null
	# Accept AgenticStudioPage or a plain Resource with the fields.
	return res


static func find_by_title(title: String) -> Resource:
	var want: String = title.strip_edges().to_lower()
	if want.is_empty():
		return null
	for item: Variant in list_pages():
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = item
		if str(d.get("title", "")).strip_edges().to_lower() == want:
			return load_page(str(d.get("path", "")))
	return null


static func resolve_page_path(path_or_title: String) -> String:
	var s: String = path_or_title.strip_edges()
	if s.is_empty():
		return ""
	# Prefer an existing resource path; tolerate wrong extensions from models.
	if s.begins_with("res://"):
		if ResourceLoader.exists(s) or FileAccess.file_exists(s):
			return s
		var as_tres: String = s.get_basename() + ".tres"
		if ResourceLoader.exists(as_tres) or FileAccess.file_exists(as_tres):
			return as_tres
		var base: String = s.get_file().get_basename().replace("_", " ")
		var by_title: Resource = find_by_title(base)
		if by_title != null:
			return str(by_title.resource_path)
		# Slug match under studio dirs.
		for kind: String in [PageScript.KIND_CHARACTER, PageScript.KIND_ASSET]:
			var candidate: String = "%s/%s.tres" % [dir_for_kind(kind), s.get_file().get_basename()]
			if ResourceLoader.exists(candidate) or FileAccess.file_exists(candidate):
				return candidate
		return s
	var page: Resource = find_by_title(s)
	if page == null:
		return ""
	return str(page.resource_path)


static func save_page(page: Resource, path: String = "") -> Dictionary:
	## Returns {ok, path, error}.
	ensure_dirs()
	if page == null:
		return {"ok": false, "path": "", "error": "page is null"}
	var kind: String = str(page.get("kind"))
	if kind.is_empty():
		kind = PageScript.KIND_CHARACTER
	if kind != PageScript.KIND_CHARACTER and kind != PageScript.KIND_ASSET:
		return {"ok": false, "path": "", "error": "kind must be character or asset"}
	var title: String = str(page.get("title")).strip_edges()
	if title.is_empty():
		return {"ok": false, "path": "", "error": "title is required"}
	var save_path: String = path.strip_edges()
	if save_path.is_empty():
		save_path = str(page.resource_path)
	if save_path.is_empty():
		save_path = path_for_title(kind, title)
	page.resource_path = save_path
	var err: Error = ResourceSaver.save(page, save_path)
	if err != OK:
		return {"ok": false, "path": save_path, "error": "save failed (%d)" % err}
	return {"ok": true, "path": save_path, "error": ""}


static func add_image_path(page: Resource, image_path: String) -> void:
	if page == null:
		return
	var p: String = image_path.strip_edges()
	if p.is_empty():
		return
	var images: PackedStringArray = PackedStringArray(page.get("image_paths"))
	for existing: String in images:
		if existing == p:
			return
	images.append(p)
	page.set("image_paths", images)


func add_link(from_path: String, to_path: String) -> Dictionary:
	## Instance method so EditorUndoRedoManager can call do/undo on this store.
	return add_link_static(from_path, to_path)


func remove_link(from_path: String, to_path: String) -> Dictionary:
	return remove_link_static(from_path, to_path)


static func add_link_static(from_path: String, to_path: String) -> Dictionary:
	## Idempotent append of to_path onto from_path page links. Saves immediately.
	from_path = from_path.strip_edges()
	to_path = to_path.strip_edges()
	if from_path.is_empty() or to_path.is_empty():
		return {"ok": false, "error": "from and to paths are required"}
	var page: Resource = load_page(from_path)
	if page == null:
		return {"ok": false, "error": "page not found: %s" % from_path}
	if load_page(to_path) == null and not FileAccess.file_exists(to_path):
		return {"ok": false, "error": "link target not found: %s" % to_path}
	var links: PackedStringArray = PackedStringArray(page.get("links"))
	for existing: String in links:
		if existing == to_path:
			return {"ok": true, "error": "", "path": from_path, "added": false}
	links.append(to_path)
	page.set("links", links)
	var saved: Dictionary = save_page(page, from_path)
	if not bool(saved.get("ok", false)):
		return {"ok": false, "error": str(saved.get("error", "save failed")), "path": from_path}
	return {"ok": true, "error": "", "path": from_path, "added": true}


static func remove_link_static(from_path: String, to_path: String) -> Dictionary:
	from_path = from_path.strip_edges()
	to_path = to_path.strip_edges()
	var page: Resource = load_page(from_path)
	if page == null:
		return {"ok": false, "error": "page not found: %s" % from_path}
	var links: PackedStringArray = PackedStringArray(page.get("links"))
	var next: PackedStringArray = PackedStringArray()
	var removed: bool = false
	for existing: String in links:
		if existing == to_path:
			removed = true
			continue
		next.append(existing)
	if not removed:
		return {"ok": true, "error": "", "path": from_path, "removed": false}
	page.set("links", next)
	var saved: Dictionary = save_page(page, from_path)
	if not bool(saved.get("ok", false)):
		return {"ok": false, "error": str(saved.get("error", "save failed")), "path": from_path}
	return {"ok": true, "error": "", "path": from_path, "removed": true}


static func delete_page(path: String) -> Dictionary:
	## Deletes the page .tres, strips inbound links, and removes studio-local image folder.
	## Does not delete res://inbox/ meshes or scene nodes.
	path = path.strip_edges()
	if path.is_empty():
		return {"ok": false, "error": "path required"}
	if not path.begins_with(STUDIO_ROOT + "/"):
		return {"ok": false, "error": "refusing to delete outside res://studio/"}
	# Drop links that pointed at this page.
	for item: Variant in list_pages():
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var other_path: String = str((item as Dictionary).get("path", ""))
		if other_path.is_empty() or other_path == path:
			continue
		remove_link_static(other_path, path)
	# Remove studio-local images folder next to the page, if present.
	var images_dir: String = "%s/%s_images" % [
		path.get_base_dir(),
		path.get_file().get_basename(),
	]
	_remove_dir_recursive(images_dir)
	var abs_path: String = ProjectSettings.globalize_path(path)
	if FileAccess.file_exists(abs_path):
		var err: Error = DirAccess.remove_absolute(abs_path)
		if err != OK:
			return {"ok": false, "error": "could not delete page (%d)" % err}
	# Sidecar .uid if present.
	var uid_path: String = path + ".uid"
	var uid_abs: String = ProjectSettings.globalize_path(uid_path)
	if FileAccess.file_exists(uid_abs):
		DirAccess.remove_absolute(uid_abs)
	return {"ok": true, "error": ""}


static func _remove_dir_recursive(dir_path: String) -> void:
	var abs_dir: String = ProjectSettings.globalize_path(dir_path)
	if not DirAccess.dir_exists_absolute(abs_dir):
		return
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name: String = dir.get_next()
	while name != "":
		if name == "." or name == ".." or name.begins_with("._"):
			name = dir.get_next()
			continue
		var child: String = "%s/%s" % [dir_path, name]
		if dir.current_is_dir():
			_remove_dir_recursive(child)
		else:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(child))
		name = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(abs_dir)


static func copy_image_into_page_folder(page_path: String, source_path: String) -> Dictionary:
	## Copy an absolute or res:// image next to the page under images/. Returns {ok, path, error}.
	page_path = page_path.strip_edges()
	source_path = source_path.strip_edges()
	if page_path.is_empty() or source_path.is_empty():
		return {"ok": false, "path": "", "error": "paths required"}
	var page_dir: String = page_path.get_base_dir()
	var images_dir: String = "%s/%s_images" % [
		page_dir,
		page_path.get_file().get_basename(),
	]
	_ensure_dir(images_dir)
	var file_name: String = source_path.get_file()
	if file_name.is_empty():
		file_name = "image.png"
	var dest: String = "%s/%s" % [images_dir, file_name]
	var src_abs: String = source_path
	if source_path.begins_with("res://") or source_path.begins_with("user://"):
		src_abs = ProjectSettings.globalize_path(source_path)
	var dest_abs: String = ProjectSettings.globalize_path(dest)
	var err: Error = DirAccess.copy_absolute(src_abs, dest_abs)
	if err != OK:
		return {"ok": false, "path": "", "error": "copy failed (%d)" % err}
	return {"ok": true, "path": dest, "error": ""}
