# AgenticStudio — project outline

Status: draft, revised 2026-10-05
Companion to studio-white-paper.md
Name: AgenticStudio
Location: thumb drive, folder `/AgenticStudio`
Dev machine: M2 Pro Mac Mini, 16GB, until the MacBook arrives
Engine: Godot 4.7, GDScript, plus a Python sidecar

## Goal

A better editor experience than VS Code, inside Godot. The chat window is the front door: plan a job, run an agent, or auto-approve an agent. Models are selected, not hardcoded. Configuration is where local models, external models, and linked tools (Blender and the rest) get added.

The book of pages, the asset pipeline, and generated meshes stay in the project. They are later phases. Cel-shading is not a requirement. A cel shader may ship later as an optional preview material. It is not applied by default and it is not a done-check.

VS Code is the bootstrap editor only, used to write AgenticStudio until the dock can edit its own project.

Acceptance test for the first milestone: pick a configured model, plan a change in the chat, run it with auto-approve on the safe tools, and get an undoable edit in the open scene plus a transcript that survives a reload.

## Repo

Own folder on the thumb drive, own repo, not the Mini's existing workspace.

```
/AgenticStudio/
  project.godot
  addons/agentic_studio/   # editor plugin
  sidecar/                 # Python, uv
  res://studio/            # the book, versioned with the game
    characters/
    assets/
    jobs/                  # or user://jobs if job logs should stay out of git
  inbox/                   # GLBs waiting for import
  studio-white-paper.md
  studio-outline.md
```

The plugin must also run inside a later game project, so keep game scenes out of `addons/agentic_studio/`.

## Phase 0 — bootstrap

- Godot 4.7 native Apple Silicon. No Rosetta.
- `uv` for the sidecar. VS Code only to write this repo.
- Empty plugin enabled. Empty dock opens.
- `.gitignore` for weights, inbox caches, job logs.

Done when the editor loads the plugin and the dock is blank.

## Phase 1 — configuration

This is first, ahead of pages and assets.

- Settings dock or dialog, stored outside the game scenes (`user://` or a project config the plugin owns).
- Model list: add a local model (endpoint, name, context) and an external model (endpoint, name, key stored outside the repo).
- Picker on the chat: choose the model for the next job. Locked while that job runs.
- Tool links: path to Blender, and a slot for other local programs. Unused links are fine. A missing path fails the job that needs it, not the editor.
- Run mode on the chat: Plan, Run, Auto-approve.
  - Plan writes a plan into the transcript and does not edit.
  - Run executes and asks on writes.
  - Auto-approve executes reads and scene edits. Delete and project-settings changes still ask.

Done when a local model and an external model both appear in the picker, Blender's path is saved, and Plan produces a transcript without touching the scene.

## Phase 2 — chat

The dock is a view on job files. It does not own the work.

- Tabs are open jobs. History is the folder. Transcript collapsed by default.
- A job file: prompt, model id, mode, stage, log, output path.
- Diff for script writes. Undo name for scene writes. Reject rolls that action back.
- Status line: selected model loaded or not, linked tool running or not.
- Quitting the editor and reopening shows the same jobs.

Done when a chat tab can plan, run, and auto-approve against the configured model, and the history is still there after a restart.

## Phase 3 — editor hands

In-process, through `EditorInterface`. No MCP. This is what makes the chat a better editor than VS Code.

- Read open scene tree, selection, inspector values, recent errors.
- Write a node, set a property, attach a script. One undo action named for the job.
- Play from editor, capture errors, capture a viewport shot, stop.
- Done check: scene opens, scripts compile, short play stays clean. Retries capped.

Done when an auto-approved job adds a node and one undo removes it.

## Phase 4 — sidecar

- Plugin starts it. Loopback only.
- One tool list, used by every configured model: `list_pages`, `get_page`, `get_images`, `create_asset`, `check_scene`, `link`. Page tools may no-op until Phase 5.
- Local and external models share that list. The chat's model picker chooses which endpoint.
- On the Mini, 7B or 14B for the local coder. Unload it before a heavy linked tool runs.

Done when the model selected in the chat is the one that actually answered, and a tool call lands in the job file.

## Phase 5 — pages

Character and asset only. Reference material for later prompts, not a blocker for the chat.

- Resource: title, kind, notes, tags, image paths, links.
- List and form. Drop images onto a character page.
- Files under `res://studio/`. No canvas, no whiteboard.

Done when a character page with thumbnails survives a reload and `get_page` returns it.

## Phase 6 — stand-in asset job

`create_asset` on the Mini does not generate.

- Copy a known GLB into the inbox.
- Decimate is skipped, or run in headless Blender if that path is configured.
- Import, instance, link an asset page back to the character page.
- No default shader. A cel material is an optional preview, applied only if the job asks for it.
- Fail if the import does not open. Do not fail for a missing cel shade.

Done when a prompt against the character page, unattended, leaves an instanced mesh and a linked asset page. One undo reverts the scene write.

## Phase 7 — laptop

When the 20-core / 48GB machine arrives. Same repo, copied off the thumb drive.

- External drive for weights and inbox. Boot drive under about 70%.
- MLX server added as a local model in the existing configuration. Not Core ML, not the Neural Engine.
- Replace the stand-in with one shape backend, linked like Blender. Shape-only, lower steps, decimate to a face budget. Paint and cel preview stay off unless the job asks.
- Unload the coder before the shape pass. Stay awake on power. Lid open.
- MetalFX Temporal is a game-project setting, not an AgenticStudio feature. Development cap 60. Shipped build offers 60, 120, and display rate. Physics tick stays 60.

Done when the same prompt produces a generated mesh under the face budget, using the model and the Blender path already configured.

## Explicitly later

Item, system, storyboard, and task pages. Whiteboard. Token streaming. Optional cel-shader preview. PBR paint. A second generator. MetalFX frame interpolation. Tailscale. Dogfooding AgenticStudio to edit AgenticStudio, once Phase 3 is real.

## Non-goals

- Driving this editor from VS Code or from a Godot MCP server.
- Joining the Debian box or the Mini's existing agent stack.
- Targeting the Neural Engine from the agent loop.
- A chat panel that keeps history only in memory.
- Imposing an art style on imported meshes.
