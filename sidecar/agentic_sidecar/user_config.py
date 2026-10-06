"""Read AgenticStudio user://agentic_studio.cfg. Never prints API keys."""

from __future__ import annotations

import os
import re
from pathlib import Path
from typing import Any

ROLE_PLANNER = "planner"
ROLE_CODER = "coder"
KIND_EXTERNAL = "external"
KIND_LOCAL = "local"

DEFAULT_CODER_CONTEXT = 8192
DEFAULT_PLANNER_CONTEXT = 32768

STABLE_GROK_ID = "provider_grok"


def default_config_paths() -> list[Path]:
    """Candidate paths for Godot user://agentic_studio.cfg on this machine."""
    env = os.environ.get("AGENTIC_STUDIO_CFG", "").strip()
    out: list[Path] = []
    if env:
        out.append(Path(env).expanduser())
    home = Path.home()
    # macOS Godot 4 userdata
    out.append(
        home
        / "Library/Application Support/Godot/app_userdata/AgenticStudio/agentic_studio.cfg"
    )
    # Linux
    out.append(home / ".local/share/godot/app_userdata/AgenticStudio/agentic_studio.cfg")
    # Windows-ish (WSL / rare)
    out.append(home / "AppData/Roaming/Godot/app_userdata/AgenticStudio/agentic_studio.cfg")
    return out


def find_config_path(explicit: str | Path | None = None) -> Path | None:
    if explicit:
        p = Path(explicit).expanduser()
        return p if p.is_file() else None
    for p in default_config_paths():
        if p.is_file():
            return p
    return None


def _parse_packed_string_array(raw: str) -> list[str]:
    # PackedStringArray("a", "b") or plain csv
    raw = raw.strip()
    m = re.match(r'PackedStringArray\((.*)\)\s*$', raw, re.DOTALL)
    if not m:
        if raw.startswith('"') and raw.endswith('"'):
            return [raw.strip('"')]
        return [x.strip().strip('"') for x in raw.split(",") if x.strip()]
    inner = m.group(1).strip()
    if not inner:
        return []
    return [s.strip().strip('"') for s in re.findall(r'"([^"]*)"', inner)]


def _parse_godot_cfg(text: str) -> dict[str, dict[str, str]]:
    sections: dict[str, dict[str, str]] = {}
    current = ""
    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith(";") or s.startswith("#"):
            continue
        if s.startswith("[") and s.endswith("]"):
            current = s[1:-1].strip()
            sections.setdefault(current, {})
            continue
        if "=" not in s or not current:
            continue
        key, val = s.split("=", 1)
        sections[current][key.strip()] = val.strip().strip('"')
    return sections


def load_config(path: str | Path | None = None) -> dict[str, Any]:
    cfg_path = find_config_path(path)
    if cfg_path is None:
        raise FileNotFoundError(
            "agentic_studio.cfg not found — set AGENTIC_STUDIO_CFG or open the project in Godot once"
        )
    sections = _parse_godot_cfg(cfg_path.read_text(encoding="utf-8", errors="replace"))
    general = sections.get("general", {})
    models_sec = sections.get("models", {})
    ids = _parse_packed_string_array(models_sec.get("ids", ""))
    models: list[dict[str, Any]] = []
    by_id: dict[str, dict[str, Any]] = {}
    for mid in ids:
        sec = sections.get(f"model.{mid}", {})
        if not sec:
            continue
        kind = sec.get("kind", KIND_LOCAL)
        role = (sec.get("role") or ROLE_CODER).strip().lower()
        if role not in (ROLE_PLANNER, ROLE_CODER):
            role = ROLE_CODER
        try:
            ctx = int(float(sec.get("context_length", "0") or 0))
        except ValueError:
            ctx = 0
        if ctx <= 0:
            ctx = DEFAULT_PLANNER_CONTEXT if role == ROLE_PLANNER else DEFAULT_CODER_CONTEXT
        model: dict[str, Any] = {
            "id": mid,
            "display_name": sec.get("display_name", mid),
            "kind": kind,
            "role": role,
            "base_url": sec.get("base_url", ""),
            "model_name": sec.get("model_name", ""),
            "context_length": ctx,
            "provider": sec.get("provider", ""),
            "accepts_images": sec.get("accepts_images", "false").lower() in ("true", "1"),
        }
        if kind == KIND_EXTERNAL:
            model["api_key"] = sec.get("api_key", "")
        models.append(model)
        by_id[mid] = model

    planner_id = general.get("selected_planner_id", "")
    coder_id = general.get("selected_coder_id", "") or general.get("selected_model_id", "")
    return {
        "path": str(cfg_path),
        "models": models,
        "by_id": by_id,
        "selected_planner_id": planner_id,
        "selected_coder_id": coder_id,
    }


def normalize_role(role: str) -> str:
    return ROLE_PLANNER if (role or "").strip().lower() == ROLE_PLANNER else ROLE_CODER


def validate_role_endpoint(model: dict[str, Any] | None, expected_role: str = "") -> dict[str, Any]:
    display = (model or {}).get("display_name") or (model or {}).get("id") or "model"
    if not model:
        label = expected_role or "model"
        return {"ok": False, "error": f"No {label} selected"}
    role = normalize_role(str(model.get("role", ROLE_CODER)))
    if expected_role and role != normalize_role(expected_role):
        return {"ok": False, "error": f"{display} has role={role}, expected {expected_role}"}
    base_url = str(model.get("base_url") or "").strip()
    if not base_url:
        provider = str(model.get("provider") or "")
        if provider == "grok_build" or role == ROLE_PLANNER:
            return {
                "ok": False,
                "error": f"Build URL missing for {display} — set base_url in Settings",
            }
        return {"ok": False, "error": f"Base URL missing for {display}"}
    model_name = str(model.get("model_name") or "").strip()
    if not model_name:
        return {"ok": False, "error": f"Model name missing for {display}"}
    if str(model.get("kind")) == KIND_EXTERNAL:
        key = str(model.get("api_key") or "").strip()
        if not key:
            return {
                "ok": False,
                "error": f"API key missing for {display} — set it in Settings (user:// only)",
            }
    return {
        "ok": True,
        "error": "",
        "model": model,
        "base_url": base_url,
        "model_name": model_name,
        "role": role,
        "display_name": display,
    }


def resolve_selected(role: str, path: str | Path | None = None) -> dict[str, Any]:
    """Return validate_role_endpoint result for the selected planner or coder. No fallback."""
    cfg = load_config(path)
    want = normalize_role(role)
    mid = cfg["selected_planner_id"] if want == ROLE_PLANNER else cfg["selected_coder_id"]
    model = cfg["by_id"].get(mid)
    return validate_role_endpoint(model, want)


def model_log_fields(model: dict[str, Any]) -> dict[str, Any]:
    base = str(model.get("base_url") or "")
    safe_url = "" if _url_looks_secret(base) else base
    return {
        "model_id": str(model.get("id") or ""),
        "role": normalize_role(str(model.get("role") or ROLE_CODER)),
        "display_name": str(model.get("display_name") or ""),
        "kind": str(model.get("kind") or ""),
        "model_name": str(model.get("model_name") or ""),
        "base_url": safe_url,
    }


def _url_looks_secret(url: str) -> bool:
    u = url.lower()
    if "api_key=" in u or "apikey=" in u or "token=" in u:
        return True
    if "://" in u and "@" in u.split("://", 1)[-1]:
        return True
    return False


def estimate_tokens(text: str) -> int:
    if not text:
        return 0
    return (len(text) + 3) // 4


def pack_context(
    required: dict[str, str],
    session_lines: list[str],
    page_lines: list[str],
    budget: int,
) -> dict[str, Any]:
    keys = ["system", "op_schema", "page_id", "last_play_error", "prompt"]
    parts = [str(required[k]) for k in keys if required.get(k)]
    for k, v in required.items():
        if k in keys:
            continue
        if v:
            parts.append(str(v))
    required_text = "\n\n".join(parts)
    required_tokens = estimate_tokens(required_text)
    if required_tokens > budget:
        return {
            "ok": False,
            "error": (
                f"context budget exceeded: required block needs {required_tokens} "
                f"tokens, budget is {budget}"
            ),
            "used_tokens": required_tokens,
            "budget": budget,
            "extra": "",
        }
    remaining = budget - required_tokens
    kept_session = list(session_lines)
    while kept_session and estimate_tokens("\n".join(kept_session)) > remaining:
        kept_session.pop(0)
    session_block = "\n".join(kept_session)
    after = max(0, remaining - estimate_tokens(session_block))
    kept_page = list(page_lines)
    while kept_page and estimate_tokens("\n".join(kept_page)) > after:
        kept_page.pop(0)
    page_block = "\n".join(kept_page)
    extras: list[str] = []
    if session_block:
        extras.append("Session log (trimmed):\n" + session_block)
    if page_block:
        extras.append("Page notes (trimmed):\n" + page_block)
    extra = "\n\n".join(extras)
    return {
        "ok": True,
        "error": "",
        "extra": extra,
        "used_tokens": required_tokens + estimate_tokens(extra),
        "budget": budget,
    }
