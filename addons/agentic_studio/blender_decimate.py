# Optional headless Blender decimate for AgenticStudio create_asset.
# Usage: blender --background --python blender_decimate.py -- <in.glb> <out.glb>
import sys

try:
    import bpy
except ImportError:
    sys.exit(2)

argv = sys.argv
if "--" in argv:
    argv = argv[argv.index("--") + 1 :]
else:
    argv = []

if len(argv) < 2:
    print("usage: blender_decimate.py <in.glb> <out.glb>")
    sys.exit(2)

in_path = argv[0]
out_path = argv[1]

bpy.ops.wm.read_factory_settings(use_empty=True)
# Clear default objects if any remain.
for obj in list(bpy.data.objects):
    bpy.data.objects.remove(obj, do_unlink=True)

bpy.ops.import_scene.gltf(filepath=in_path)
meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
for obj in meshes:
    bpy.context.view_layer.objects.active = obj
    mod = obj.modifiers.new(name="AgenticDecimate", type="DECIMATE")
    mod.ratio = 0.5
    bpy.ops.object.modifier_apply(modifier=mod.name)

bpy.ops.export_scene.gltf(filepath=out_path, export_format="GLB")
print("AgenticStudio decimate wrote", out_path)
