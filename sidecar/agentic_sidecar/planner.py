"""OpenAI-compatible chat helper. Sidecar never writes scenes itself."""

from __future__ import annotations

import json
import re
from typing import Any

import httpx

from .client import ApplyClient
from .user_config import (
    ROLE_PLANNER,
    model_log_fields,
    pack_context,
    resolve_selected,
)

PLAN_SYSTEM = (
    "You are the AgenticStudio planner. You never receive the apply API and never write "
    "scenes, project.godot, or autoloads. Write-shaped replies are discarded. "
    "Local class knowledge is only Node3D, MeshInstance3D, CollisionShape3D, Camera3D, "
    "and the cited page's script — everything else goes through class_get. "
    "Do not load or dump a full Godot class index. "
    "Start with list_pages/get_page. Use check_page_drift, scene_hierarchy, node_properties, "
    "class_get (one class, only after node_properties when uncertain), signal_list, "
    "resource_find, input_map_list, list_dir/read_file (only paths a cited page points at), "
    "log_read, editor_screenshot/screenshot as needed. "
    "May cite a page image and, after import, the play frame or editor_screenshot when "
    "accepts_images is set. Do not call image_generate or mesh_from_image. "
    "Do not receive sampler progress. "
    "Your plan MUST name: (1) page_id, (2) the intended op for the coder, "
    "(3) the play check that counts as done. "
    "Do not claim you edited the scene. Quote page notes when asked."
)

_WRITE_MARKERS = (
    '"write_file"',
    '"delete_file"',
    '"add_node"',
    '"set_property"',
    '"create_asset"',
    '"image_generate"',
    '"mesh_from_image"',
    '"node_duplicate"',
    '"node_rename"',
    '"node_reparent"',
    '"node_move"',
    '"signal_connect"',
    '"resource_assign"',
    '"script_patch"',
    '"script_attach"',
    '"input_map_ensure"',
)


def chat_completions(
    *,
    base_url: str,
    model: str,
    messages: list[dict[str, Any]],
    api_key: str = "",
    kind: str = "local",
    timeout: float = 120.0,
) -> dict[str, Any]:
    url = base_url.rstrip("/") + "/chat/completions"
    headers = {"Content-Type": "application/json"}
    # Bearer only for external rows.
    if kind == "external" and api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    body = {"model": model, "messages": messages, "temperature": 0.2}
    with httpx.Client(timeout=timeout) as client:
        resp = client.post(url, headers=headers, json=body)
        resp.raise_for_status()
        return resp.json()


def _has_write(content: str) -> bool:
    lower = content.lower()
    return any(m in lower for m in _WRITE_MARKERS)


def _extract_page_id(text: str) -> str:
    m = re.search(r"page_id[\"'\s:=]+([a-zA-Z0-9_\-]+)", text)
    if m:
        return m.group(1)
    m2 = re.search(r"\bgoblin_shaman\b", text)
    return m2.group(0) if m2 else ""


def plan_prompt(
    prompt: str,
    *,
    base_url: str = "",
    model: str = "",
    api_key: str = "",
    client: ApplyClient | None = None,
    config_path: str | None = None,
    use_config: bool = False,
) -> dict[str, Any]:
    """
    Call the selected planner (or explicit URL). Never applies ops.
    When use_config=True, reads user:// config for the planner row — no coder fallback.
    """
    apply = client or ApplyClient()
    model_row: dict[str, Any] = {}
    if use_config or (not base_url and not model):
        checked = resolve_selected(ROLE_PLANNER, config_path)
        if not checked.get("ok"):
            return {"ok": False, "error": checked.get("error", "planner invalid"), "text": ""}
        model_row = checked["model"]
        base_url = checked["base_url"]
        model = checked["model_name"]
        api_key = str(model_row.get("api_key") or "") if model_row.get("kind") == "external" else ""
    elif not base_url or not model:
        return {"ok": False, "error": "planner base_url and model are required", "text": ""}

    context_bits: list[str] = []
    page_lines: list[str] = []
    try:
        pages = apply.list_pages()
        context_bits.append(
            "pages=" + json.dumps(pages.get("result", pages), ensure_ascii=False)[:2000]
        )
    except OSError as exc:
        context_bits.append(f"list_pages unavailable: {exc}")

    budget = int(model_row.get("context_length") or 32768) if model_row else 32768
    packed = pack_context(
        {
            "system": PLAN_SYSTEM,
            "op_schema": "Plan fields: page_id, intended_op, play_check_done.",
            "page_id": "(planner must name page_id)",
            "last_play_error": "",
            "prompt": prompt,
            "plugin_context": "\n".join(context_bits),
        },
        [],
        page_lines,
        budget,
    )
    if not packed.get("ok"):
        return {"ok": False, "error": packed.get("error", "budget"), "text": ""}

    user_content = prompt
    if packed.get("extra"):
        user_content += "\n\n" + packed["extra"]
    if context_bits and "plugin_context" not in (packed.get("extra") or ""):
        user_content += "\n\nContext:\n" + "\n".join(context_bits)

    messages = [
        {"role": "system", "content": PLAN_SYSTEM},
        {"role": "user", "content": user_content},
    ]
    data = chat_completions(
        base_url=base_url,
        model=model,
        messages=messages,
        api_key=api_key,
        kind=str(model_row.get("kind") or ("external" if api_key else "local")),
    )
    choice = (data.get("choices") or [{}])[0]
    message = choice.get("message") or {}
    text = str(message.get("content") or "")
    if _has_write(text):
        return {
            "ok": False,
            "error": "planner write discarded — not applied",
            "text": text,
            "page_id": "",
            "model": model_log_fields(model_row) if model_row else {},
        }
    return {
        "ok": True,
        "error": "",
        "text": text,
        "page_id": _extract_page_id(text),
        "model": model_log_fields(model_row) if model_row else {
            "model_id": "",
            "role": ROLE_PLANNER,
            "display_name": model,
            "model_name": model,
        },
    }
