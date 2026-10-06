# Studio — project white paper

Status: draft, 2026-10-05
Machine: development starts on the M2 Pro Mac Mini, 16GB, until the MacBook Pro 14" 20-core GPU, 48GB, 1TB arrives November 2026. Shape generation is not tested on the Mini. Editor tools, pages, and the job dock are.
Engine: Godot 4.7, GDScript
This document is the mission. It will be refined. It is not a design spec for every panel.

## Mission

Studio is an editor plugin and a sidecar that replace VS Code on the new machine. Godot is the editor and the task hub. Ideas, references, and generated work live in the project. A local agent reads those pages, makes the thing, checks it in the editor, and fixes what the editor reports.

The acceptance test: a character page holds notes and thumbnails for a goblin shaman. One prompt — "create a new goblin shaman, base it on the thumbnails in this character reference" — produces an instanced, decimated, cel-shaded mesh in the open scene, linked back to that page. The job can finish while nobody is watching.

## What it is

- A book of pages in `res://studio/`, versioned with the game. Page kinds: character, item, system, storyboard, task, asset.
- A dock that is a view on job files: tabs, transcript, history, inbox, provider.
- A sidecar the plugin starts. It calls the local model and Grok, runs the shape generator, and drives Blender headless.
- In-process editor tools: read the live scene, write through the undo stack, play, read errors, screenshot.

## What it is not

- Not a VS Code extension, and not a client of a Godot MCP server. Those face the wrong way.
- Not a borrowed chat dock. The panel is ours because a job is not a transcript.
- Not a cluster product. The Debian box and the Mini stay on their own workspaces. Tailscale is optional reachability, added later.
- Not a PBR pipeline. Default art direction is cel-shaded, low-to-mid poly, Zelda-like. Shape only, then decimate, then a Godot shader. The paint pass is off unless a job asks for it.

## How a job runs

1. The prompt names a page. The page is the argument: notes, tags, thumbnail paths.
2. The sidecar writes a job file and appends events. The dock renders them.
3. Local model for mechanical steps. Grok if the job is marked hard, or after local retries are spent. One tool list either way.
4. Scene and script writes go through `EditorInterface`, one undo action named for the job.
5. Done means the scene opens, scripts compile, and a short play-from-editor run stays clean. Failure returns the error and a screenshot for one more turn. Retries are capped.
6. A prop job also fails if the mesh is over its face budget or the import has no material.
7. One heavy stage at a time. The local coder is unloaded before a shape pass. The machine stays awake on power. Closing the lid is not a supported way to run a job.

## v1

Enough to pass the goblin shaman test. Nothing else.

- Pages: a list, a form, dropped images, tags. Character and asset kinds only.
- Tools: `list_pages`, `get_page`, `get_images`, `create_asset`, `check_scene`, `link`.
- Dock: tabs as jobs, history as the job folder, transcript collapsed, provider locked while running, diff and undo name on writes, inbox thumbnail.
- Shape generator: one backend, shape-only, decimate to a face budget, GLB into the inbox, import, instance, assign the cel material.
- Checks: naming, folder, face budget, scene opens, play stays clean.

## Later, not now

Item, system, storyboard, and task pages. A whiteboard. Token streaming. The texture paint pass. A second generator. Tailscale notifications. Anything that cannot be named in a tool call.

## First build order

1. Page records and the folder layout.
2. Live scene read, undoable write, play-and-verify.
3. Job file and the dock as a view on it.
4. Shape job, decimate, import, link back to the character page.
5. Run the goblin shaman prompt unattended. Refine the mission from what broke.

## Standing constraints

- 48GB holds the coder next to the editor, or a generation, not both.
- 1TB needs an external drive for weights and the inbox. Boot drive stays under about 70% full.
- Generator time on this chip is minutes for a shape pass. That is acceptable. Sleep mid-job is not.
