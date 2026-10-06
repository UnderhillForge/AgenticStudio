# AgenticStudio

Godot 4.7 editor plugin that runs Plan / Run / Auto-approve jobs against configured local or external models. The dock is the front door; pages and assets stay in the project.

## Requirements

- Godot **4.7** (arm64 on Apple Silicon)
- Optional: [uv](https://github.com/astral-sh/uv) for the Python sidecar

## Quick start

1. Open this folder as a Godot project (or copy `addons/agentic_studio/` into another game project).
2. Enable **AgenticStudio** under Project → Project Settings → Plugins.
3. In the dock, open Settings and add a model (`base_url` + `model_name`). Config lives in `user://agentic_studio.cfg`.
4. Use **Plan** to inspect pages and files, **Run** to apply edits with confirm, or **Auto-approve** for safe ops (property set / add-child under the scene root).

## Layout

| Path | Role |
|------|------|
| `addons/agentic_studio/` | Editor plugin (dock, tools, play gate, apply server) |
| `sidecar/` | Optional Python client — plans/calls the model; never writes scenes |
| `studio/` | Character and asset pages (`.tres`), versioned with the project |
| `fixtures/` | Stand-in mesh used by `create_asset` |
| `dev_docs/` | White paper and build notes |

## Modes

- **Plan** — read-only tools (`list_pages`, `get_page`, `list_dir`, `read_file`, `screenshot`, `check_page_drift`)
- **Run** — writes ask for confirm; one undo action per job
- **Auto-approve** — allows safe scene edits; script body, delete, and project settings still ask

Scene/resource writes require a `page_id`. After scene writes, the play gate parses scripts, plays briefly with a temporary PlayProbe, and returns a structured result (including an optional frame under `user://agentic/`).

## Sidecar

Loopback apply API on `127.0.0.1:8765` while the editor is open:

```bash
cd sidecar && uv sync
uv run agentic-sidecar ping
```

See `sidecar/README.md`.

## License

Proprietary for now — Underhill Forge.
