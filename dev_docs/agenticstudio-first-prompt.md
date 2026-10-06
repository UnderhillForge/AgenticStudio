# AgenticStudio — first prompt

Paste this into the coding agent with the workspace set to `/AgenticStudio` on the thumb drive. Godot 4.7 native Apple Silicon. Do not start the shape generator, pages, or a cel shader.

---

You are writing AgenticStudio, a Godot 4.7 editor plugin that will replace VS Code as the agent client. The repo is `/AgenticStudio`. VS Code is only the bootstrap editor. Do not add a Godot MCP server, do not call Herd, and do not import meshes.

Build Phase 0 and Phase 1 only.

Phase 0 — plugin boots

- `addons/agentic_studio/plugin.cfg` and an `EditorPlugin` that adds a dock.
- Dock opens blank except for a status line: no model selected.
- Plugin enables from Project Settings without errors on Godot 4.7, Apple Silicon, no Rosetta.
- `.gitignore` ignores weights, `inbox/`, and job logs.

Phase 1 — configuration and the chat shell

Settings live in `user://agentic_studio.cfg`, not in the game scenes and not in git.

- Model list. Each entry has id, display name, kind (`local` or `external`), base URL, model name, optional context length. External entries may store an API key in the config. Never write the key into the repo.
- Tool links. A path field for Blender, plus a list of named extra programs (name, path). A missing path is saved. It must not stop the editor from opening. A job that needs a missing path fails that job only.
- Chat model picker, filled from the saved list. Selection locks while a job is running.
- Run mode control with three values: Plan, Run, Auto-approve.
  - Plan appends a plan to the job transcript and must not edit the scene.
  - Run is stored on the job. Writes will ask later. For this prompt, Run only records the mode.
  - Auto-approve is stored on the job. Reads and scene edits will proceed later. Delete and project-settings changes will still ask. For this prompt, Auto-approve only records the mode.
- A job file per send, under `user://agentic_studio/jobs/`. Fields: prompt, model id, mode, stage, log. The dock is a view on those files. Tabs are open jobs. Restarting the editor reloads them.
- Status line shows the selected model and whether the Blender path is set.

Do not implement scene edits, play-from-editor, the sidecar, page records, GLB import, or any shader. Stub the send action so Plan writes a one-line plan into the job log ("plan only — no scene edit") using the selected model id. If no model is selected, the send action reports that and writes nothing.

Done when: the plugin enables, a local model and an external model can be saved and both appear in the picker, a Blender path can be saved, Plan creates a job file without touching any scene, and reopening the editor shows that job.

Keep GDScript typed where Godot 4.7 allows it. Match the editor theme. No new autoloads.
