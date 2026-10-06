"""CLI: ping | apply | plan | run — never writes scenes/project.godot/autoloads."""

from __future__ import annotations

import argparse
import json
import sys

from .client import ApplyClient, DEFAULT_HOST, DEFAULT_PORT
from .planner import plan_prompt
from .runner import run_harness


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

    run_p = sub.add_parser(
        "run",
        help="One model op → apply → at most one fix through the plugin (harness loop)",
    )
    run_p.add_argument("--prompt", required=True)
    run_p.add_argument("--base-url", required=True)
    run_p.add_argument("--model", required=True, help="Model name for the chat API")
    run_p.add_argument(
        "--model-id",
        default="",
        help="Id recorded in session jsonl (defaults to --model)",
    )
    run_p.add_argument("--mode", default="auto_approve", choices=["auto_approve", "run"])
    run_p.add_argument(
        "--page-id",
        default="",
        help="Optional page_id hint for the prompt; never rewritten onto the op",
    )
    run_p.add_argument("--api-key", default="")

    args = parser.parse_args(argv)
    client = ApplyClient(host=args.host, port=args.port, timeout=180.0)

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

    if args.cmd == "run":
        result = run_harness(
            prompt=args.prompt,
            base_url=args.base_url,
            model=args.model,
            mode=args.mode,
            page_id=args.page_id,
            api_key=args.api_key,
            model_id=args.model_id or args.model,
            client=client,
        )
        print(json.dumps(result, indent=2))
        return 0 if bool(result.get("ok")) else 1

    return 1


if __name__ == "__main__":
    sys.exit(main())
