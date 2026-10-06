class_name AgenticStudioPage
extends Resource
## Character or asset page under res://studio/. Project data, not a job.

const KIND_CHARACTER: String = "character"
const KIND_ASSET: String = "asset"

@export var title: String = ""
@export var kind: String = KIND_CHARACTER
@export var notes: String = ""
@export var tags: PackedStringArray = PackedStringArray()
@export var image_paths: PackedStringArray = PackedStringArray()
## Paths to other page .tres resources under res://studio/.
@export var links: PackedStringArray = PackedStringArray()


func to_dict() -> Dictionary:
	return {
		"title": title,
		"kind": kind,
		"notes": notes,
		"tags": Array(tags),
		"image_paths": Array(image_paths),
		"links": Array(links),
	}


func apply_dict(data: Dictionary) -> void:
	title = str(data.get("title", title))
	kind = str(data.get("kind", kind))
	notes = str(data.get("notes", notes))
	tags = PackedStringArray(data.get("tags", tags))
	image_paths = PackedStringArray(data.get("image_paths", image_paths))
	links = PackedStringArray(data.get("links", links))
