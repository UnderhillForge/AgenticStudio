# AgenticStudio sidecar

Plans and calls the model. **Never** writes scenes, `project.godot`, or autoloads.

The Godot editor plugin owns apply / play / undo / result JSON on loopback TCP
(`127.0.0.1:8765` by default).

## Setup

```bash
cd sidecar
uv sync
```

## Ping the plugin

With the AgenticStudio editor open:

```bash
uv run agentic-sidecar ping
```

## Apply ops (plugin enforces policy)

```bash
uv run agentic-sidecar apply --mode auto_approve --op '{"tool":"add_node","arguments":{"type":"Node3D","name":"FromSidecar","page_id":"goblin_shaman"}}'
```

Confirm-class ops (`write_file` of `.gd`, `delete_file`, script property) return
`needs_confirm` under `auto_approve` and do not write.

## Plan against a model

```bash
uv run agentic-sidecar plan --prompt "Quote the Goblin Shaman notes" \
  --base-url http://192.168.68.55:11434/v1 --model qwen2.5-coder:7b
```

The sidecar calls the model; page/scene writes still go only through the plugin apply API.
