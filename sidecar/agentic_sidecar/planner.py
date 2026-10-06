"""OpenAI-compatible chat helper. Sidecar never writes scenes itself."""

from __future__ import annotations

import json
from typing import Any

import httpx

from .client import ApplyClient


PLAN_SYSTEM = (
    "You are planning only for AgenticStudio. You may ask the sidecar to call "
    "list_pages, get_page, read_scene, and check_page_drift via the plugin. "
    "Do not claim you edited the scene. Quote page notes when asked."
)


def chat_completions(
    *,
    base_url: str,
    model: str,
    messages: list[dict[str, Any]],
    api_key: str = "",
    timeout: float = 120.0,
) -> dict[str, Any]:
    url = base_url.rstrip("/") + "/chat/completions"
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    body = {"model": model, "messages": messages, "temperature": 0.2}
    with httpx.Client(timeout=timeout) as client:
        resp = client.post(url, headers=headers, json=body)
        resp.raise_for_status()
        return resp.json()


def plan_prompt(
    prompt: str,
    *,
    base_url: str,
    model: str,
    api_key: str = "",
    client: ApplyClient | None = None,
) -> str:
    """Fetch page context from the plugin, then ask the model for a plan."""
    apply = client or ApplyClient()
    context_bits: list[str] = []
    try:
        pages = apply.list_pages()
        context_bits.append("pages=" + json.dumps(pages.get("result", pages), ensure_ascii=False)[:2000])
    except OSError as exc:
        context_bits.append(f"list_pages unavailable: {exc}")
    messages = [
        {"role": "system", "content": PLAN_SYSTEM},
        {"role": "user", "content": prompt + "\n\nContext:\n" + "\n".join(context_bits)},
    ]
    data = chat_completions(base_url=base_url, model=model, messages=messages, api_key=api_key)
    choice = (data.get("choices") or [{}])[0]
    message = choice.get("message") or {}
    return str(message.get("content") or "")
