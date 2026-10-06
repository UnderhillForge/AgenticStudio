extends SceneTree

func _initialize() -> void:
	var s := VSplitContainer.new()
	print("signals:")
	for sig: Dictionary in s.get_signal_list():
		var n: String = str(sig.get("name", ""))
		if n.find("drag") >= 0 or n.find("split") >= 0:
			print("  ", n, " args=", sig.get("args"))
	s.split_offsets = PackedInt32Array([120])
	print("after set split_offsets=", s.split_offsets, " split_offset=", s.split_offset)
	s.split_offset = 50
	print("after set split_offset=", s.split_offset, " split_offsets=", s.split_offsets)
	s.free()
	quit(0)
