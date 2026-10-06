# AgenticStudio — fourth prompt

Paste this into the coding agent with the workspace set to `/Volumes/NO NAME/AgenticStudio`. Run and Auto-approve already edit through EditorInterface. Plan does not. The transcript is a read-only TextEdit. Do not redo any of that.

---

Add a play check to executing jobs. Do not add pages, mesh import, shaders, or a Godot MCP server.

New tool, same list for every model:

- `play_scene` — play the current scene from the editor, wait up to 3 seconds, collect debugger errors, stop, return the error lines. No file write.

Plan must not call it. Run may call it without asking. Auto-approve may call it without asking. It counts toward the 4 tool-round cap.

After the model stops, if the job mode is Run or Auto-approve and a write happened, call `play_scene` once even if the model did not. Stage `done` only if that play returns no errors. Otherwise stage `failed`, append the errors to the log, and leave the undo action in place so one undo still reverts the job.

Headless check: play result parsing, no live editor. Live check: Auto-approve "add a Node3D named AgentProbe under the current scene root", confirm stage `done` and the play line in the log, then one undo removes the node. A second job that adds a script with a deliberate parse error must finish `failed` with the error in the selectable log and must not keep the game running.

Done when those two live checks pass and Plan still does not edit or play.

Keep GDScript typed where Godot 4.7 allows it. No new autoloads.
