class_name AgenticStudioAssetSupport
extends RefCounted
## Stand-in create_asset for the Mini: copy known GLB, optional decimate, import, instance.

const PageScript = preload("res://addons/agentic_studio/page.gd")
const PageStoreScript = preload("res://addons/agentic_studio/page_store.gd")
const ConfigScript = preload("res://addons/agentic_studio/config.gd")

const STAND_IN_GLB: String = "res://fixtures/stand_in_mesh.glb"
const INBOX_DIR: String = "res://inbox"
const DECIMATE_SCRIPT: String = "res://addons/agentic_studio/blender_decimate.py"


static func inbox_path_for(character_slug: String, file_name: String = "stand_in.glb") -> String:
	var slug: String = character_slug.strip_edges()
	if slug.is_empty():
		slug = "asset"
	return "%s/%s_%s" % [INBOX_DIR, slug, file_name]


static func ensure_inbox_dir() -> void:
	var abs_dir: String = ProjectSettings.globalize_path(INBOX_DIR)
	if DirAccess.dir_exists_absolute(abs_dir):
		return
	DirAccess.make_dir_recursive_absolute(abs_dir)


static func copy_stand_in_to_inbox(character_title: String, source_glb: String = "") -> Dictionary:
	## Returns {ok, path, error, source}.
	ensure_inbox_dir()
	var src: String = source_glb.strip_edges()
	if src.is_empty():
		src = STAND_IN_GLB
	var src_abs: String = src
	if src.begins_with("res://") or src.begins_with("user://"):
		src_abs = ProjectSettings.globalize_path(src)
	if not FileAccess.file_exists(src_abs) and not FileAccess.file_exists(src):
		return {"ok": false, "path": "", "error": "stand-in GLB missing: %s" % src, "source": src}
	var slug: String = PageStoreScript.slugify(character_title)
	var dest: String = inbox_path_for(slug, "stand_in.glb")
	var dest_abs: String = ProjectSettings.globalize_path(dest)
	var err: Error = DirAccess.copy_absolute(src_abs, dest_abs)
	if err != OK:
		# Retry via FileAccess if DirAccess.copy fails across volumes.
		var in_f: FileAccess = FileAccess.open(src_abs, FileAccess.READ)
		if in_f == null:
			in_f = FileAccess.open(src, FileAccess.READ)
		if in_f == null:
			return {"ok": false, "path": "", "error": "could not read stand-in (%d)" % err, "source": src}
		var out_f: FileAccess = FileAccess.open(dest, FileAccess.WRITE)
		if out_f == null:
			return {"ok": false, "path": "", "error": "could not write inbox GLB", "source": src}
		out_f.store_buffer(in_f.get_buffer(in_f.get_length()))
		out_f.close()
		in_f.close()
	return {"ok": true, "path": dest, "error": "", "source": src}


static func maybe_decimate(inbox_glb: String) -> Dictionary:
	## Optional Blender decimate. Missing/empty Blender path skips without failing.
	## Returns {ok, path, skipped, error, log}.
	var blender: String = ConfigScript.get_blender_path().strip_edges()
	if blender.is_empty():
		return {
			"ok": true,
			"path": inbox_glb,
			"skipped": true,
			"error": "",
			"log": "decimate skipped (Blender path empty)",
		}
	if not FileAccess.file_exists(blender):
		return {
			"ok": true,
			"path": inbox_glb,
			"skipped": true,
			"error": "",
			"log": "decimate skipped (Blender missing at %s)" % blender,
		}
	var script_abs: String = ProjectSettings.globalize_path(DECIMATE_SCRIPT)
	if not FileAccess.file_exists(script_abs):
		return {
			"ok": true,
			"path": inbox_glb,
			"skipped": true,
			"error": "",
			"log": "decimate skipped (script missing)",
		}
	var in_abs: String = ProjectSettings.globalize_path(inbox_glb)
	var out_path: String = inbox_glb.get_basename() + "_decimated.glb"
	var out_abs: String = ProjectSettings.globalize_path(out_path)
	var args: PackedStringArray = PackedStringArray([
		"--background",
		"--python",
		script_abs,
		"--",
		in_abs,
		out_abs,
	])
	var output: Array = []
	var exit_code: int = OS.execute(blender, args, output, true, false)
	if exit_code != 0 or not FileAccess.file_exists(out_abs):
		return {
			"ok": true,
			"path": inbox_glb,
			"skipped": true,
			"error": "",
			"log": "decimate failed/skipped (exit=%d); using original" % exit_code,
		}
	# Require a real GLB header; otherwise keep the original stand-in.
	var header: FileAccess = FileAccess.open(out_abs, FileAccess.READ)
	var magic: String = ""
	if header != null:
		magic = header.get_buffer(4).get_string_from_ascii()
		header.close()
	if magic != "glTF" or FileAccess.get_file_as_bytes(out_abs).size() < 64:
		return {
			"ok": true,
			"path": inbox_glb,
			"skipped": true,
			"error": "",
			"log": "decimate output invalid; using original",
		}
	return {
		"ok": true,
		"path": out_path,
		"skipped": false,
		"error": "",
		"log": "decimate ok -> %s" % out_path,
	}


func _await_importable(path: String, timeout_ms: int = 25000) -> Resource:
	var tree: SceneTree = EditorInterface.get_base_control().get_tree()
	var fs: EditorFileSystem = EditorInterface.get_resource_filesystem()
	fs.update_file(path)
	fs.scan()
	var guard_ms: int = Time.get_ticks_msec() + timeout_ms
	var packed: Resource = null
	while Time.get_ticks_msec() < guard_ms:
		while fs.is_scanning() and Time.get_ticks_msec() < guard_ms:
			await tree.process_frame
		await tree.process_frame
		if ResourceLoader.exists(path):
			packed = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE)
			if packed != null:
				return packed
		await tree.process_frame
	# Last attempt without cache ignore semantics changing.
	if ResourceLoader.exists(path):
		packed = load(path)
	return packed


func import_and_instance(inbox_glb: String, instance_name: String) -> Dictionary:
	## Editor-only. Returns {ok, node, path, error, log}.
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return {"ok": false, "node": null, "path": "", "error": "no open scene", "log": "import failed: no open scene"}

	var packed: Resource = await _await_importable(inbox_glb)
	if packed == null:
		return {
			"ok": false,
			"node": null,
			"path": inbox_glb,
			"error": "import did not open: %s" % inbox_glb,
			"log": "create_asset failed: import did not open",
		}

	var instance: Node = null
	if packed is PackedScene:
		instance = (packed as PackedScene).instantiate()
	else:
		return {
			"ok": false,
			"node": null,
			"path": inbox_glb,
			"error": "import opened but is not a scene: %s" % packed.get_class(),
			"log": "create_asset failed: import is not a PackedScene",
		}
	if instance == null:
		return {
			"ok": false,
			"node": null,
			"path": inbox_glb,
			"error": "instantiate returned null",
			"log": "create_asset failed: instantiate null",
		}

	var name: String = instance_name.strip_edges()
	if name.is_empty():
		name = "StandInAsset"
	instance.name = name
	# No default material. Do not assign a cel shader.
	return {
		"ok": true,
		"node": instance,
		"path": inbox_glb,
		"error": "",
		"log": "import ok path=%s" % inbox_glb,
	}


static func create_asset_page(character_title: String, glb_path: String) -> Dictionary:
	## Project data under res://studio/assets/. Returns {ok, path, error, title}.
	PageStoreScript.ensure_dirs()
	var title: String = "%s Asset" % character_title.strip_edges()
	if title.strip_edges() == "Asset":
		title = "Stand-in Asset"
	var page: Resource = PageScript.new()
	page.set("title", title)
	page.set("kind", PageScript.KIND_ASSET)
	page.set("notes", "Stand-in mesh for %s (%s)" % [character_title, glb_path])
	page.set("tags", PackedStringArray(["stand_in", "glb"]))
	page.set("image_paths", PackedStringArray())
	page.set("links", PackedStringArray())
	var path: String = PageStoreScript.path_for_title(PageScript.KIND_ASSET, title)
	var saved: Dictionary = PageStoreScript.save_page(page, path)
	if not bool(saved.get("ok", false)):
		return {
			"ok": false,
			"path": "",
			"error": str(saved.get("error", "save failed")),
			"title": title,
		}
	return {
		"ok": true,
		"path": str(saved.get("path", path)),
		"error": "",
		"title": title,
	}
