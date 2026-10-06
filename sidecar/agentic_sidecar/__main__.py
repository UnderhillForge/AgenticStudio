"""CLI: ping | apply | plan — never writes scenes/project.godot/autoloads."""

from __future__ import annotations

import argparse
import json
import sys

from .client import ApplyClient, DEFAULT_HOST, DEFAULT_PORT
from .planner import plan_prompt


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="agentic-sidecar")
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("ping", help="Ping the plugin apply server")

    apply_p = sub.add_parser("apply", help="Send ops to the plugin")
    apply_p.add_argument("--mode", default="auto_approve", choices=["auto_approve", "run"])
    apply_p.add_argument("--op", action="append", default=[], help="JSON op object (repeatable)")
    apply_p.add_argument("--model-id", default="sidecar")

    plan_p = sub.add_parser("plan", help="Call a model with plugin page context")
    plan_p.add_argument("--prompt", required=True)
    plan_p.add_argument("--base-url", required=True)
    plan_p.add_argument("--model", required=True)
    plan_p.add_argument("--api-key", default="")

    args = parser.parse_args(argv)
    client = ApplyClient(host=args.host, port=args.port)

    if args.cmd == "ping":
        print(json.dumps(client.ping(), indent=2))
        return 0

    if args.cmd == "apply":
        ops = [json.loads(raw) for raw in args.op]
        print(json.dumps(client.apply_ops(ops, mode=args.mode, model_id=args.model_id), indent=2))
        return 0

    if args.cmd == "plan":
        text = plan_prompt(
            args.prompt,
            base_url=args.base_url,
            model=args.model,
            api_key=args.api_key,
            client=client,
        )
        print(text)
        return 0

    return 1


if __name__ == "__main__":
    sys.exit(main())
