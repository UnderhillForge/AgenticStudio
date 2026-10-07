class_name AgenticStudioGenerateSupport
extends RefCounted
## Headless image_generate (Draw Things CLI) and mesh_from_image (Blender decimate/export).
## No ComfyUI / cloud / progress watching. CLI path and model filename come from user:// only.

const ConfigScript = preload("res://addons/agentic_studio/config.gd")
const PageStoreScript = preload("res://addons/agentic_studio/page_store.gd")
const AssetSupportScript = preload("res://addons/agentic_studio/asset_support.gd")

const GENERATED_ROOT: String = "res://studio/generated"
const DEFAULT_SIZE: int = 1024


static func ensure_generated_dirs(page_id: String = "") -> String:
	PageStoreScript.ensure_dirs()
	_ensure_dir(GENERATED_ROOT)
	var slug: String = PageStoreScript.slugify(page_id) if not page_id.strip_edges().is_empty() else ""
	if slug.is_empty():
		return GENERATED_ROOT
	var dir_path: String = "%s/%s" % [GENERATED_ROOT, slug]
	_ensure_dir(dir_path)
	return dir_path


static func _ensure_dir(path: String) -> void:
	var abs_path: String = ProjectSettings.globalize_path(path)
	if DirAccess.dir_exists_absolute(abs_path):
		return
	DirAccess.make_dir_recursive_absolute(abs_path)


## Named pre-spawn check. Never invents CLI path or checkpoint filename.
static func validate_drawthings_settings() -> Dictionary:
	var cli: String = ConfigScript.get_drawthings_cli().strip_edges()
	if cli.is_empty():
		return {"ok": false, "error": "drawthings_cli missing — set the CLI path in Settings"}
	if not FileAccess.file_exists(cli):
		return {"ok": false, "error": "drawthings_cli not found at %s" % cli}
	var models_dir: String = ConfigScript.get_drawthings_models_dir().strip_edges()
	if models_dir.is_empty():
		return {
			"ok": false,
			"error": "drawthings_models_dir missing — set the models directory in Settings",
		}
	if not DirAccess.dir_exists_absolute(models_dir):
		return {"ok": false, "error": "drawthings_models_dir not found at %s" % models_dir}
	var model: String = ConfigScript.get_drawthings_model().strip_edges()
	if model.is_empty():
		return {
			"ok": false,
			"error": "drawthings_model missing — set the checkpoint filename in Settings",
		}
	return {
		"ok": true,
		"error": "",
		"cli": cli,
		"models_dir": models_dir,
		"model": model,
	}


static func validate_blender_path() -> Dictionary:
	var blender: String = ConfigScript.get_blender_path().strip_edges()
	if blender.is_empty():
		return {"ok": false, "error": "blender_path missing — set Blender path in Settings"}
	if not FileAccess.file_exists(blender):
		return {"ok": false, "error": "blender_path not found at %s" % blender}
	return {"ok": true, "error": "", "blender": blender}


static func output_png_path(page_id: String) -> String:
	var dir_path: String = ensure_generated_dirs(page_id)
	var stamp: int = Time.get_unix_time_from_system()
	return "%s/gen_%d.png" % [dir_path, stamp]


static func output_glb_path(page_id: String, stem: String = "mesh") -> String:
	var dir_path: String = ensure_generated_dirs(page_id)
	var safe: String = PageStoreScript.slugify(stem)
	if safe.is_empty():
		safe = "mesh"
	return "%s/%s_decimated.glb" % [dir_path, safe]


## One-shot local generate. No cloud flag, no API key, no progress UI.
## Returns {ok, path, error, stdout}.
static func run_image_generate(
	prompt: String,
	page_id: String,
	reference_image: String = ""
) -> Dictionary:
	var checked: Dictionary = validate_drawthings_settings()
	if not bool(checked.get("ok", false)):
		return {
			"ok": false,
			"path": "",
			"error": str(checked.get("error", "drawthings settings incomplete")),
			"stdout": "",
		}
	var text: String = prompt.strip_edges()
	if text.is_empty():
		return {"ok": false, "path": "", "error": "prompt is required", "stdout": ""}
	var out_res: String = output_png_path(page_id)
	var out_abs: String = ProjectSettings.globalize_path(out_res)
	var args: PackedStringArray = PackedStringArray([
		"generate",
		"--local",
		"--disable-preview",
		"--no-download-missing",
		"--models-dir",
		str(checked.get("models_dir", "")),
		"--model",
		str(checked.get("model", "")),
		"--prompt",
		text,
		"--width",
		str(DEFAULT_SIZE),
		"--height",
		str(DEFAULT_SIZE),
		"--output",
		out_abs,
	])
	var ref: String = reference_image.strip_edges()
	if not ref.is_empty():
		var ref_abs: String = ref
		if ref.begins_with("res://") or ref.begins_with("user://"):
			ref_abs = ProjectSettings.globalize_path(ref)
		if not FileAccess.file_exists(ref_abs):
			return {
				"ok": false,
				"path": "",
				"error": "reference image not found: %s" % ref,
				"stdout": "",
			}
		args.append("--image")
		args.append(ref_abs)

	var output: Array = []
	var exit_code: int = OS.execute(str(checked.get("cli", "")), args, output, true, false)
	var stdout_text: String = "\n".join(PackedStringArray(output))
	if exit_code != 0:
		return {
			"ok": false,
			"path": "",
			"error": "drawthings_cli failed (exit=%d)" % exit_code,
			"stdout": stdout_text,
		}
	if not FileAccess.file_exists(out_abs):
		return {
			"ok": false,
			"path": "",
			"error": "drawthings_cli exited 0 but PNG missing: %s" % out_res,
			"stdout": stdout_text,
		}
	return {
		"ok": true,
		"path": out_res,
		"error": "",
		"stdout": stdout_text,
	}


## Attach PNG to page.image_paths and save. Returns previous image_paths for undo.
static func attach_image_to_page(page_path: String, image_path: String) -> Dictionary:
	var page: Resource = PageStoreScript.load_page(page_path)
	if page == null:
		return {"ok": false, "error": "page not found: %s" % page_path, "previous": PackedStringArray()}
	var previous: PackedStringArray = PackedStringArray(page.get("image_paths"))
	PageStoreScript.add_image_path(page, image_path)
	var saved: Dictionary = PageStoreScript.save_page(page, page_path)
	if not bool(saved.get("ok", false)):
		return {
			"ok": false,
			"error": str(saved.get("error", "save failed")),
			"previous": previous,
		}
	return {
		"ok": true,
		"error": "",
		"previous": previous,
		"path": str(saved.get("path", page_path)),
		"image_path": image_path,
	}


## Undo helpers kept alive via EditorUndoRedoManager do/undo references.
func apply_page_images(page_path: String, images: PackedStringArray) -> void:
	var page: Resource = PageStoreScript.load_page(page_path)
	if page == null:
		return
	page.set("image_paths", images)
	PageStoreScript.save_page(page, page_path)


func restore_page_images(page_path: String, previous: PackedStringArray) -> void:
	apply_page_images(page_path, previous)


func delete_generated_file(path: String) -> void:
	var p: String = path.strip_edges()
	if p.is_empty():
		return
	if not p.begins_with(GENERATED_ROOT):
		return
	var abs_path: String = ProjectSettings.globalize_path(p)
	if FileAccess.file_exists(abs_path):
		DirAccess.remove_absolute(abs_path)
	var import_sidecar: String = abs_path + ".import"
	if FileAccess.file_exists(import_sidecar):
		DirAccess.remove_absolute(import_sidecar)


## Resource.get takes one argument. Never call String.get or Dictionary-style defaults on a String.
static func _page_string_field(page: Resource, field: String) -> String:
	if page == null or field.is_empty():
		return ""
	var v: Variant = page.get(field)
	if typeof(v) == TYPE_NIL:
		return ""
	if typeof(v) == TYPE_STRING:
		return v
	return str(v)


static func _page_string_array_field(page: Resource, field: String) -> PackedStringArray:
	if page == null or field.is_empty():
		return PackedStringArray()
	var v: Variant = page.get(field)
	if typeof(v) == TYPE_PACKED_STRING_ARRAY:
		return v
	if typeof(v) == TYPE_ARRAY:
		return PackedStringArray(v)
	return PackedStringArray()


static func page_has_image(page: Resource, image_path: String) -> bool:
	if page == null:
		return false
	var want: String = image_path.strip_edges().replace("\\", "/")
	if want.is_empty():
		return false
	for existing: String in _page_string_array_field(page, "image_paths"):
		if existing.strip_edges().replace("\\", "/") == want:
			return true
	return false


static func _is_mesh_path(path: String) -> bool:
	var ext: String = path.get_extension().to_lower()
	return ext == "glb" or ext == "gltf"


## Mesh file already associated with the page — never derive a sculpt from a PNG.
static func find_mesh_on_page(page: Resource) -> Dictionary:
	if page == null:
		return {"ok": false, "path": "", "error": "page is null"}
	var candidates: PackedStringArray = PackedStringArray()
	for img: String in _page_string_array_field(page, "image_paths"):
		if _is_mesh_path(img) and FileAccess.file_exists(ProjectSettings.globalize_path(img)):
			candidates.append(img)
	for link_path: String in _page_string_array_field(page, "links"):
		var linked: Resource = PageStoreScript.load_page(link_path)
		if linked == null:
			continue
		for limg: String in _page_string_array_field(linked, "image_paths"):
			if _is_mesh_path(limg) and FileAccess.file_exists(ProjectSettings.globalize_path(limg)):
				candidates.append(limg)
		_collect_mesh_paths_from_text(_page_string_field(linked, "notes"), candidates)
	_collect_mesh_paths_from_text(_page_string_field(page, "notes"), candidates)
	# Deduplicate while keeping order.
	var seen: Dictionary = {}
	var unique: PackedStringArray = PackedStringArray()
	for c: String in candidates:
		if seen.has(c):
			continue
		seen[c] = true
		unique.append(c)
	if unique.is_empty():
		return {
			"ok": false,
			"path": "",
			"error": "no mesh on page yet — image-to-mesh is not available",
		}
	return {"ok": true, "path": unique[0], "error": "", "candidates": unique}


static func _collect_mesh_paths_from_text(text: String, out: PackedStringArray) -> void:
	if text.is_empty():
		return
	# Match res://…glb|gltf tokens in notes.
	var i: int = 0
	while true:
		var at: int = text.find("res://", i)
		if at < 0:
			break
		var end: int = at
		while end < text.length():
			var ch: String = text[end]
			var code: int = ch.unicode_at(0)
			var ok_ch: bool = (
				(code >= 97 and code <= 122)
				or (code >= 65 and code <= 90)
				or (code >= 48 and code <= 57)
				or ch == "/" or ch == "_" or ch == "-" or ch == "."
			)
			if not ok_ch:
				break
			end += 1
		var token: String = text.substr(at, end - at)
		if _is_mesh_path(token) and FileAccess.file_exists(ProjectSettings.globalize_path(token)):
			out.append(token)
		i = end


## Decimate + export an existing mesh. Fails named if blender_path empty or mesh missing.
static func decimate_export_mesh(source_mesh: String, page_id: String) -> Dictionary:
	var blender_check: Dictionary = validate_blender_path()
	if not bool(blender_check.get("ok", false)):
		return {
			"ok": false,
			"path": "",
			"error": str(blender_check.get("error", "blender_path missing")),
			"log": "",
		}
	var src: String = source_mesh.strip_edges()
	if src.is_empty() or not _is_mesh_path(src):
		return {
			"ok": false,
			"path": "",
			"error": "no mesh on page yet — image-to-mesh is not available",
			"log": "",
		}
	var src_abs: String = src
	if src.begins_with("res://") or src.begins_with("user://"):
		src_abs = ProjectSettings.globalize_path(src)
	if not FileAccess.file_exists(src_abs):
		return {
			"ok": false,
			"path": "",
			"error": "mesh file missing: %s" % src,
			"log": "",
		}
	var script_abs: String = ProjectSettings.globalize_path(AssetSupportScript.DECIMATE_SCRIPT)
	if not FileAccess.file_exists(script_abs):
		return {
			"ok": false,
			"path": "",
			"error": "decimate script missing",
			"log": "",
		}
	var out_res: String = output_glb_path(page_id, src.get_file().get_basename())
	var out_abs: String = ProjectSettings.globalize_path(out_res)
	var args: PackedStringArray = PackedStringArray([
		"--background",
		"--python",
		script_abs,
		"--",
		src_abs,
		out_abs,
	])
	var output: Array = []
	var exit_code: int = OS.execute(
		str(blender_check.get("blender", "")), args, output, true, false
	)
	var log_text: String = "\n".join(PackedStringArray(output))
	if exit_code != 0 or not FileAccess.file_exists(out_abs):
		return {
			"ok": false,
			"path": "",
			"error": "blender decimate/export failed (exit=%d)" % exit_code,
			"log": log_text,
		}
	var header: FileAccess = FileAccess.open(out_abs, FileAccess.READ)
	var magic: String = ""
	if header != null:
		magic = header.get_buffer(4).get_string_from_ascii()
		header.close()
	if magic != "glTF" or FileAccess.get_file_as_bytes(out_abs).size() < 64:
		return {
			"ok": false,
			"path": "",
			"error": "blender export invalid (not a GLB)",
			"log": log_text,
		}
	return {
		"ok": true,
		"path": out_res,
		"error": "",
		"log": "decimate ok -> %s" % out_res,
		"source": src,
	}
