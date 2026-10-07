"""Harness loop: one model op → apply → at most one fix. Never writes scenes itself."""

from __future__ import annotations

import json
import re
from typing import Any

from .client import ApplyClient
from .planner import chat_completions
from .user_config import (
    ROLE_CODER,
    model_log_fields,
    pack_context,
    resolve_selected,
)

RUN_SYSTEM = (
    "You are executing one AgenticStudio scene op through the plugin apply API. "
    "Reply with exactly one tool call or a single JSON object "
    '{"tool":"...","arguments":{...}} — no prose, no plan-only text. '
    "play_scene is the plugin gate after an allow write — not a tool you call. "
    "Local class knowledge is only Node3D, MeshInstance3D, CollisionShape3D, Camera3D, "
    "and the cited page script; everything else uses class_get (one class). "
    "Allowed write tools: add_node, set_property, node_duplicate, node_rename, "
    "node_reparent, node_move, signal_connect, resource_assign. "
    "Confirm-only (plugin will return needs_confirm unless confirmed): "
    "script_patch, script_attach, input_map_ensure, write_file, delete_file. "
    "add_node arguments MUST use keys type, name, page_id "
    '(example: {"tool":"add_node","arguments":{"type":"Node3D","name":"HarnessMarker","page_id":"goblin_shaman"}}). '
    "set_property arguments MUST use keys path, property, value, page_id; "
    "properties absent from the node snapshot are rejected. "
    "Scene/resource writes MUST include page_id in arguments (slug like goblin_shaman). "
    "Do not silently invent scripts for signal_connect — method must already exist. "
    "Do not claim you edited the scene yourself."
)

FIX_SYSTEM = (
    "The previous AgenticStudio apply/play failed. Propose exactly one fix op as JSON "
    '{"tool":"...","arguments":{...}} or one tool call. '
    "Keep the same page_id as the failed op. "
    "Read the play.errors list. If a node export like BoomProbe.arm caused a runtime crash, "
    'fix it with set_property: {"tool":"set_property","arguments":'
    '{"path":"BoomProbe","property":"arm","value":false,"page_id":"<same>"}}. '
    "Do not re-add a node that already exists. Do not write scripts or project.godot. "
    "Plan-only replies are ignored."
)


def _message_text(data: dict[str, Any]) -> tuple[str, list[dict[str, Any]]]:
    choice = (data.get("choices") or [{}])[0]
    message = choice.get("message") or {}
    content = str(message.get("content") or "").strip()
    tool_calls = message.get("tool_calls") or []
    if not isinstance(tool_calls, list):
        tool_calls = []
    return content, tool_calls


def _quote_bare_identifiers(text: str) -> str:
    """Tolerate near-JSON like {"name": add_node, ...} from local models."""

    def repl(match: re.Match[str]) -> str:
        key = match.group(1)
        val = match.group(2)
        if val in ("true", "false", "null") or re.match(r"^-?\d+(\.\d+)?$", val):
            return match.group(0)
        return f'{key}: "{val}"'

    return re.sub(r'("?[A-Za-z_][A-Za-z0-9_]*"?)\s*:\s*([A-Za-z_][A-Za-z0-9_]*)\b', repl, text)


def _parse_json_object(text: str) -> dict[str, Any] | None:
    text = text.strip()
    if not text:
        return None
    # Strip markdown fences.
    fence = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.DOTALL)
    if fence:
        text = fence.group(1)
    start = text.find("{")
    end = text.rfind("}")
    if start < 0 or end <= start:
        return None
    chunk = text[start : end + 1]
    for candidate in (chunk, _quote_bare_identifiers(chunk)):
        try:
            parsed = json.loads(candidate)
        except json.JSONDecodeError:
            continue
        if isinstance(parsed, dict):
            return parsed
    return None


def _normalize_op_args(tool: str, args: dict[str, Any]) -> dict[str, Any]:
    """Map common local-model aliases onto plugin argument names. Never invent page_id."""
    out = dict(args)
    if tool == "add_node":
        if not str(out.get("type") or "").strip():
            for key in ("node_type", "class", "class_name", "node_class"):
                if str(out.get(key) or "").strip():
                    out["type"] = out[key]
                    break
        if not str(out.get("name") or "").strip():
            for key in ("node_name", "node", "id"):
                if str(out.get(key) or "").strip():
                    out["name"] = out[key]
                    break
    elif tool == "set_property":
        if not str(out.get("path") or "").strip():
            for key in ("node", "node_path", "target"):
                if str(out.get(key) or "").strip():
                    out["path"] = out[key]
                    break
        if not str(out.get("property") or "").strip():
            for key in ("prop", "property_name", "key"):
                if str(out.get(key) or "").strip():
                    out["property"] = out[key]
                    break
        if "value" not in out:
            for key in ("val", "new_value"):
                if key in out:
                    out["value"] = out[key]
                    break
    return out


def extract_op(content: str, tool_calls: list[dict[str, Any]]) -> dict[str, Any] | None:
    """Return {tool, arguments} or None for plan-only / unparseable replies."""
    for call in tool_calls:
        if not isinstance(call, dict):
            continue
        fn = call.get("function") or {}
        if not isinstance(fn, dict):
            continue
        name = str(fn.get("name") or "").strip()
        if not name:
            continue
        raw_args = fn.get("arguments", "{}")
        if isinstance(raw_args, dict):
            args = raw_args
        else:
            try:
                parsed = json.loads(str(raw_args) or "{}")
            except json.JSONDecodeError:
                parsed = _parse_json_object(str(raw_args)) or {}
            args = parsed if isinstance(parsed, dict) else {}
        return {"tool": name, "arguments": _normalize_op_args(name, args)}

    obj = _parse_json_object(content)
    if not obj:
        return None
    # OpenAI-ish nested form
    if "function" in obj and isinstance(obj["function"], dict):
        fn = obj["function"]
        name = str(fn.get("name") or "").strip()
        args = fn.get("arguments", {})
        if isinstance(args, str):
            args = _parse_json_object(args) or {}
        if name and isinstance(args, dict):
            return {"tool": name, "arguments": _normalize_op_args(name, args)}
    tool = str(obj.get("tool") or obj.get("name") or "").strip()
    args = obj.get("arguments") or obj.get("args") or obj.get("parameters") or {}
    if isinstance(args, str):
        args = _parse_json_object(args) or {}
    if tool and isinstance(args, dict):
        return {"tool": tool, "arguments": _normalize_op_args(tool, args)}
    return None


def _page_id_of(op: dict[str, Any]) -> str:
    args = op.get("arguments") or {}
    if isinstance(args, dict):
        return str(args.get("page_id") or "").strip()
    return ""


def _op_result_flags(apply_response: dict[str, Any]) -> dict[str, Any]:
    """Normalize apply_ops response into harness flags."""
    result = apply_response.get("result") if isinstance(apply_response.get("result"), dict) else {}
    ops = result.get("ops") if isinstance(result.get("ops"), list) else []
    play = result.get("play")
    needs_confirm = False
    page_id_reject = False
    op_ok = True
    first_error = ""
    for item in ops:
        if not isinstance(item, dict):
            continue
        if bool(item.get("needs_confirm")) or str(item.get("error", "")) == "needs_confirm":
            needs_confirm = True
            op_ok = False
            first_error = "needs_confirm"
        err = str(item.get("error") or "")
        if "page_id" in err.lower():
            page_id_reject = True
            op_ok = False
            first_error = err or first_error
        if not bool(item.get("ok", False)):
            op_ok = False
            if not first_error:
                first_error = err or "op failed"
    play_ok: bool | None = None
    play_dict: dict[str, Any] | None = None
    if isinstance(play, dict):
        play_dict = play
        play_ok = bool(play.get("ok", False))
    return {
        "ops": ops,
        "play": play_dict,
        "needs_confirm": needs_confirm,
        "page_id_reject": page_id_reject,
        "op_ok": op_ok,
        "play_ok": play_ok,
        "error": first_error,
        "raw": apply_response,
    }


def _should_fix(flags: dict[str, Any]) -> bool:
    """Only play-gate failure (or failed write that still produced a play result) gets one fix.
    needs_confirm and missing page_id do not start a second apply.
    """
    if flags["needs_confirm"] or flags["page_id_reject"]:
        return False
    if flags["play"] is not None:
        return flags["play_ok"] is False
    # No play (rejected before write, or read-only): do not fix-loop.
    return False


def _succeeded(flags: dict[str, Any]) -> bool:
    if flags["needs_confirm"] or flags["page_id_reject"]:
        return False
    if not flags["op_ok"]:
        return False
    if flags["play"] is not None:
        return bool(flags["play_ok"])
    return True


def request_op(
    *,
    prompt: str,
    base_url: str,
    model: str,
    api_key: str = "",
    page_id: str = "",
    kind: str = "local",
    context_length: int = 8192,
    fix_context: dict[str, Any] | None = None,
) -> dict[str, Any] | None:
    last_play_error = ""
    if fix_context and isinstance(fix_context.get("play"), dict):
        errs = fix_context["play"].get("errors") or []
        if errs:
            last_play_error = json.dumps(errs, ensure_ascii=False)
    if fix_context is None:
        user = prompt
        if page_id:
            user += f"\n\nUse page_id={page_id} on the op."
        system = RUN_SYSTEM
    else:
        system = FIX_SYSTEM
        user = (
            "Failed apply/play result JSON:\n"
            + json.dumps(fix_context, ensure_ascii=False)
            + "\n\nOriginal prompt:\n"
            + prompt
        )
        if page_id:
            user += f"\n\nKeep page_id={page_id}."
    packed = pack_context(
        {
            "system": system,
            "op_schema": RUN_SYSTEM,
            "page_id": page_id or "(required on every op)",
            "last_play_error": last_play_error,
            "prompt": user,
        },
        [],
        [],
        max(1, int(context_length or 8192)),
    )
    if not packed.get("ok"):
        raise RuntimeError(str(packed.get("error") or "context budget exceeded"))
    if packed.get("extra"):
        user = user + "\n\n" + packed["extra"]
    data = chat_completions(
        base_url=base_url,
        model=model,
        api_key=api_key,
        kind=kind,
        messages=[
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
    )
    content, tool_calls = _message_text(data)
    return extract_op(content, tool_calls)


def apply_one(
    client: ApplyClient,
    op: dict[str, Any],
    *,
    mode: str,
    model_id: str,
    job_id: str = "",
) -> dict[str, Any]:
    return client.apply_ops([op], mode=mode, model_id=model_id, job_id=job_id)


def run_harness(
    *,
    prompt: str,
    base_url: str = "",
    model: str = "",
    mode: str = "auto_approve",
    page_id: str = "",
    api_key: str = "",
    model_id: str = "",
    client: ApplyClient | None = None,
    config_path: str | None = None,
    use_config: bool = False,
) -> dict[str, Any]:
    """One op apply; on play failure, one fix apply; never a third. Uses coder only."""
    apply = client or ApplyClient(timeout=180.0)
    model_row: dict[str, Any] = {}
    kind = "local"
    ctx = 8192
    if use_config or (not base_url and not model):
        checked = resolve_selected(ROLE_CODER, config_path)
        if not checked.get("ok"):
            return {
                "ok": False,
                "outcome": "coder_invalid",
                "error": checked.get("error", "coder invalid"),
                "attempts": [],
            }
        model_row = checked["model"]
        base_url = checked["base_url"]
        model = checked["model_name"]
        kind = str(model_row.get("kind") or "local")
        api_key = str(model_row.get("api_key") or "") if kind == "external" else ""
        ctx = int(model_row.get("context_length") or 8192)
        model_id = model_id or str(model_row.get("id") or model)
    elif not base_url or not model:
        return {
            "ok": False,
            "outcome": "coder_invalid",
            "error": "coder base_url and model are required",
            "attempts": [],
        }

    mid = model_id or model
    attempts: list[dict[str, Any]] = []
    log_fields = model_log_fields(model_row) if model_row else {
        "model_id": mid,
        "role": ROLE_CODER,
        "display_name": mid,
    }

    try:
        op = request_op(
            prompt=prompt,
            base_url=base_url,
            model=model,
            api_key=api_key,
            kind=kind,
            context_length=ctx,
            page_id=page_id,
        )
    except RuntimeError as exc:
        return {
            "ok": False,
            "outcome": "budget",
            "error": str(exc),
            "attempts": attempts,
            "model": log_fields,
        }
    if op is None:
        return {
            "ok": False,
            "outcome": "plan_only",
            "error": "model returned no applyable op",
            "attempts": attempts,
            "model": log_fields,
        }

    # Do not rewrite missing page_id — plugin rejects.
    first = apply_one(apply, op, mode=mode, model_id=mid, job_id=f"sidecar_run_{mid}_1")
    flags = _op_result_flags(first)
    attempts.append({"op": op, "apply": first, "flags": {k: flags[k] for k in flags if k != "raw"}})

    if _succeeded(flags):
        return {
            "ok": True,
            "outcome": "ok",
            "attempts": attempts,
            "play": flags["play"],
            "model": log_fields,
        }

    if not _should_fix(flags):
        outcome = "needs_confirm" if flags["needs_confirm"] else (
            "page_id_rejected" if flags["page_id_reject"] else "failed"
        )
        return {
            "ok": False,
            "outcome": outcome,
            "error": flags["error"] or outcome,
            "attempts": attempts,
            "play": flags["play"],
            "model": log_fields,
        }

    failed_page = _page_id_of(op) or page_id
    fix_ctx = {
        "op": op,
        "play": flags["play"],
        "ops": flags["ops"],
        "page_id": failed_page,
    }
    try:
        fix_op = request_op(
            prompt=prompt,
            base_url=base_url,
            model=model,
            api_key=api_key,
            kind=kind,
            context_length=ctx,
            page_id=failed_page,
            fix_context=fix_ctx,
        )
    except RuntimeError as exc:
        return {
            "ok": False,
            "outcome": "budget",
            "error": str(exc),
            "attempts": attempts,
            "play": flags["play"],
            "model": log_fields,
        }
    if fix_op is None:
        return {
            "ok": False,
            "outcome": "fix_plan_only",
            "error": "model returned no fix op",
            "attempts": attempts,
            "play": flags["play"],
            "model": log_fields,
        }

    # Still do not rewrite page_id; plugin enforces.
    second = apply_one(apply, fix_op, mode=mode, model_id=mid, job_id=f"sidecar_run_{mid}_2")
    flags2 = _op_result_flags(second)
    attempts.append({"op": fix_op, "apply": second, "flags": {k: flags2[k] for k in flags2 if k != "raw"}})

    if _succeeded(flags2):
        return {
            "ok": True,
            "outcome": "fixed",
            "attempts": attempts,
            "play": flags2["play"],
            "model": log_fields,
        }

    outcome = "needs_confirm" if flags2["needs_confirm"] else (
        "page_id_rejected" if flags2["page_id_reject"] else "fix_failed"
    )
    return {
        "ok": False,
        "outcome": outcome,
        "error": flags2["error"] or outcome,
        "attempts": attempts,
        "play": flags2["play"],
        "model": log_fields,
    }
