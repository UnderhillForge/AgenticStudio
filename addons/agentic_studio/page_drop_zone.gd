extends PanelContainer
## Drop target for image files onto a character page.

signal images_dropped(paths: PackedStringArray)

var enabled: bool = true


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if not enabled:
		return false
	return _extract_paths(data).size() > 0


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	var paths: PackedStringArray = _extract_paths(data)
	if paths.is_empty():
		return
	images_dropped.emit(paths)


func _extract_paths(data: Variant) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if typeof(data) != TYPE_DICTIONARY:
		return out
	var d: Dictionary = data
	if not d.has("files"):
		return out
	var files: Variant = d.get("files")
	if typeof(files) != TYPE_PACKED_STRING_ARRAY and typeof(files) != TYPE_ARRAY:
		return out
	for item: Variant in files:
		var path: String = str(item)
		var lower: String = path.to_lower()
		if (
			lower.ends_with(".png")
			or lower.ends_with(".jpg")
			or lower.ends_with(".jpeg")
			or lower.ends_with(".webp")
			or lower.ends_with(".svg")
			or lower.ends_with(".gif")
		):
			out.append(path)
	return out
