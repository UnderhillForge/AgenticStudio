"""TCP JSON-line client for the AgenticStudio plugin apply server."""

from __future__ import annotations

import json
import socket
from typing import Any


DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8765


class ApplyClient:
    def __init__(self, host: str = DEFAULT_HOST, port: int = DEFAULT_PORT, timeout: float = 120.0) -> None:
        self.host = host
        self.port = port
        self.timeout = timeout
        self._req_id = 0

    def call(self, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        self._req_id += 1
        payload = {"id": self._req_id, "method": method, "params": params or {}}
        data = (json.dumps(payload) + "\n").encode("utf-8")
        with socket.create_connection((self.host, self.port), timeout=self.timeout) as sock:
            sock.sendall(data)
            buf = b""
            while b"\n" not in buf:
                chunk = sock.recv(65536)
                if not chunk:
                    break
                buf += chunk
        line = buf.split(b"\n", 1)[0].decode("utf-8")
        if not line:
            raise RuntimeError("empty response from apply server")
        return json.loads(line)

    def ping(self) -> dict[str, Any]:
        return self.call("ping")

    def apply_ops(
        self,
        ops: list[dict[str, Any]],
        *,
        mode: str = "auto_approve",
        job_id: str = "",
        model_id: str = "sidecar",
    ) -> dict[str, Any]:
        params: dict[str, Any] = {"ops": ops, "mode": mode, "model_id": model_id}
        if job_id:
            params["job_id"] = job_id
        return self.call("apply_ops", params)

    def list_pages(self) -> dict[str, Any]:
        return self.call("list_pages", {})

    def get_page(self, path: str) -> dict[str, Any]:
        return self.call("get_page", {"path": path})

    def read_scene(self) -> dict[str, Any]:
        return self.call("read_scene", {})
