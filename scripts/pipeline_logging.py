#!/usr/bin/env python3

import argparse
import sys
import time


def _now_string() -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S")


def cmd_header(args: argparse.Namespace) -> int:
    print("")
    print("╔════════════════════════════════════════════════════════════╗")
    print(f"║ [START] {args.script_name}")
    print(f"║ Timestamp: {_now_string()}")
    print(f"║ Log: {args.log_file}")
    print("╚════════════════════════════════════════════════════════════╝")
    print("")
    return 0


def cmd_section(args: argparse.Namespace) -> int:
    print("")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print(f"▶ {args.title}")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print("")
    return 0


def cmd_step(args: argparse.Namespace) -> int:
    print(f"  ✓ {args.message}")
    return 0


def cmd_error(args: argparse.Namespace) -> int:
    print(f"  ✗ ERROR: {args.message}", file=sys.stderr)
    return 0


def cmd_summary(args: argparse.Namespace) -> int:
    elapsed = max(0, int(time.time()) - int(args.start_time))
    hours = elapsed // 3600
    minutes = (elapsed % 3600) // 60
    seconds = elapsed % 60
    time_str = f"{hours:02d}:{minutes:02d}:{seconds:02d}"

    print("")
    print("╔════════════════════════════════════════════════════════════╗")
    if args.status.upper() == "SUCCESS":
        print(f"║ [SUCCESS] {args.script_name}")
    else:
        print(f"║ [FAILURE] {args.script_name}")
    print(f"║ Status: {args.status}")
    print(f"║ Duration: {time_str}")
    if args.error_message:
        print(f"║ Error: {args.error_message}")
    print(f"║ Finished: {_now_string()}")
    print("╚════════════════════════════════════════════════════════════╝")
    print("")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Pipeline logging helper")
    sub = parser.add_subparsers(dest="command", required=True)

    p_header = sub.add_parser("header")
    p_header.add_argument("--script-name", required=True)
    p_header.add_argument("--log-file", required=True)
    p_header.set_defaults(func=cmd_header)

    p_section = sub.add_parser("section")
    p_section.add_argument("--title", required=True)
    p_section.set_defaults(func=cmd_section)

    p_step = sub.add_parser("step")
    p_step.add_argument("--message", required=True)
    p_step.set_defaults(func=cmd_step)

    p_error = sub.add_parser("error")
    p_error.add_argument("--message", required=True)
    p_error.set_defaults(func=cmd_error)

    p_summary = sub.add_parser("summary")
    p_summary.add_argument("--script-name", required=True)
    p_summary.add_argument("--status", required=True)
    p_summary.add_argument("--start-time", required=True)
    p_summary.add_argument("--error-message", default="")
    p_summary.set_defaults(func=cmd_summary)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
