"""CLI: ping | apply | plan | run — never writes scenes/project.godot/autoloads."""

from __future__ import annotations

import argparse
import json
import sys

from .client import ApplyClient, DEFAULT_HOST, DEFAULT_PORT
from .planner import plan_prompt
from .runner import run_harness
from .user_config import ROLE_CODER, ROLE_PLANNER, resolve_selected


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="agentic-sidecar")
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument(
        "--config",
        default="",
        help="Path to user://agentic_studio.cfg (or set AGENTIC_STUDIO_CFG)",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("ping", help="Ping the plugin apply server")

    apply_p = sub.add_parser("apply", help="Send ops to the plugin")
    apply_p.add_argument("--mode", default="auto_approve", choices=["auto_approve", "run"])
    apply_p.add_argument("--op", action="append", default=[], help="JSON op object (repeatable)")
    apply_p.add_argument("--model-id", default="sidecar")

    plan_p = sub.add_parser(
        "plan",
        help="Call the selected planner (config) or an explicit --base-url/--model",
    )
    plan_p.add_argument("--prompt", required=True)
    plan_p.add_argument("--base-url", default="", help="Override; default = selected planner")
    plan_p.add_argument("--model", default="", help="Override; default = selected planner")
    plan_p.add_argument("--api-key", default="")
    plan_p.add_argument(
        "--from-config",
        action="store_true",
        help="Require selected planner from user:// config (no coder fallback)",
    )

    run_p = sub.add_parser(
        "run",
        help="Coder harness: one op → apply → at most one fix (selected coder by default)",
    )
    run_p.add_argument("--prompt", required=True)
    run_p.add_argument("--base-url", default="", help="Override; default = selected coder")
    run_p.add_argument("--model", default="", help="Override; default = selected coder")
    run_p.add_argument(
        "--model-id",
        default="",
        help="Id recorded in session jsonl (defaults to config id or --model)",
    )
    run_p.add_argument("--mode", default="auto_approve", choices=["auto_approve", "run"])
    run_p.add_argument(
        "--page-id",
        default="",
        help="Optional page_id hint for the prompt; never rewritten onto the op",
    )
    run_p.add_argument("--api-key", default="")
    run_p.add_argument(
        "--from-config",
        action="store_true",
        help="Require selected coder from user:// config (no planner fallback)",
    )

    args = parser.parse_args(argv)
    client = ApplyClient(host=args.host, port=args.port, timeout=180.0)
    cfg_path = args.config or None

    if args.cmd == "ping":
        print(json.dumps(client.ping(), indent=2))
        return 0

    if args.cmd == "apply":
        ops = [json.loads(raw) for raw in args.op]
        print(json.dumps(client.apply_ops(ops, mode=args.mode, model_id=args.model_id), indent=2))
        return 0

    if args.cmd == "plan":
        use_cfg = bool(args.from_config) or (not args.base_url and not args.model)
        if use_cfg:
            checked = resolve_selected(ROLE_PLANNER, cfg_path)
            if not checked.get("ok"):
                print(json.dumps({"ok": False, "error": checked.get("error")}, indent=2))
                return 1
        result = plan_prompt(
            args.prompt,
            base_url=args.base_url,
            model=args.model,
            api_key=args.api_key,
            client=client,
            config_path=cfg_path,
            use_config=use_cfg,
        )
        print(json.dumps(result, indent=2) if isinstance(result, dict) else result)
        if isinstance(result, dict):
            return 0 if bool(result.get("ok")) else 1
        return 0

    if args.cmd == "run":
        use_cfg = bool(args.from_config) or (not args.base_url and not args.model)
        if use_cfg:
            checked = resolve_selected(ROLE_CODER, cfg_path)
            if not checked.get("ok"):
                print(json.dumps({"ok": False, "error": checked.get("error")}, indent=2))
                return 1
        result = run_harness(
            prompt=args.prompt,
            base_url=args.base_url,
            model=args.model,
            mode=args.mode,
            page_id=args.page_id,
            api_key=args.api_key,
            model_id=args.model_id or args.model,
            client=client,
            config_path=cfg_path,
            use_config=use_cfg,
        )
        print(json.dumps(result, indent=2))
        return 0 if bool(result.get("ok")) else 1

    return 1


if __name__ == "__main__":
    sys.exit(main())
