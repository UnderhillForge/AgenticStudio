# AgenticStudio — third prompt

Paste this into the coding agent with the workspace set to `/Volumes/NO NAME/AgenticStudio`. Plan already calls the selected model and records `planned` or `failed`. Do not redo that. Do not add pages, mesh import, shaders, or a Godot MCP server.

---

Run and Auto-approve currently only record the mode. Make them execute against the open scene, in-process, through `EditorInterface`. One undo action per job, named with the job id.

Tools, same list for every model:

- `read_scene` — open scene path, root, and child names. No file write.
- `add_node` — add a child node of a given type and name under the current scene root.
- `set_property` — set one property on a node by path.

No delete tool. No project-settings tool. A request for either records "blocked — confirm later" in the job log and does not do it.

Modes:

- Plan stays as it is. It must not call these tools.
- Run calls the model. Before `add_node` or `set_property`, the dock asks. No means skip that call and log it. `read_scene` does not ask.
- Auto-approve calls the model and runs `read_scene`, `add_node`, and `set_property` without asking. Cap the loop at 4 tool rounds. Then stop, even if the model wants more.

Each executing job begins an undo action before the first write and commits it when the job ends. One undo in the editor reverts every write from that job. A failed HTTP call marks the job `failed` and commits nothing if no write happened.

The system prompt says: planning is not executing; only these three tools exist; do not claim a node was added unless `add_node` returned ok.

Headless check: job modes and tool-result parsing, no live model, no `EditorInterface`. Live check: Auto-approve with the saved test model and the prompt "add a Node3D named AgentProbe under the current scene root". Reopen shows the node, stage `done`, and one undo removes it. Run with No on the ask leaves the scene unchanged.

Done when that live check passes and Plan still does not edit.

Keep GDScript typed where Godot 4.7 allows it. No new autoloads.
