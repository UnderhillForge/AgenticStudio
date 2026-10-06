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

## Plan (selected planner)

Reads the same `user://agentic_studio.cfg` as the dock (override with `--config` or
`AGENTIC_STUDIO_CFG`). Missing planner URL or external key fails before HTTP — no
fallback to the coder. Planner output is never applied.

```bash
uv run agentic-sidecar plan --from-config --prompt "Quote the Goblin Shaman notes; name page_id"
# Or override explicitly:
uv run agentic-sidecar plan --prompt "…" --base-url http://127.0.0.1:PORT/v1 --model grok-build
```

## Run (coder harness loop)

Uses the selected **coder**. One op → plugin apply (policy, `agentic_page`, one undo,
play gate) → on play failure, exactly one fix. `needs_confirm` / missing `page_id`
end the run. The sidecar never edits scenes or `project.godot`.

```bash
uv run agentic-sidecar run --from-config \
  --prompt "Add a Node3D named Marker under the root with page_id goblin_shaman." \
  --mode auto_approve --page-id goblin_shaman
```

Each apply appends one line under `res://.agentic/sessions/*.jsonl` with model id,
role, and display name (never the API key). Frames stay gitignored.
