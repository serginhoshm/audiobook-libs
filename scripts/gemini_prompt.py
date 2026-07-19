#!/usr/bin/env python3

import argparse
import configparser
import os
import sys
from pathlib import Path


def parse_args():
    parser = argparse.ArgumentParser(
        description="Run a general prompt using the Google Gemini API."
    )
    parser.add_argument(
        "prompt",
        nargs="?",
        default="",
        help="Single-line prompt. If empty, reads from stdin.",
    )
    parser.add_argument(
        "--model",
        default="",
        help="Gemini model to use. Defaults to ENV or config/pipeline.ini [models] gemini_model.",
    )
    parser.add_argument(
        "--env-file",
        type=Path,
        default=Path("config/translation/gemini.env"),
        help="Legacy fallback file containing GEMINI_API_KEY.",
    )
    parser.add_argument(
        "--system",
        default="",
        help="Optional system instruction to guide the model.",
    )
    return parser.parse_args()


def load_env_file(env_file):
    if not env_file.exists():
        return

    for raw_line in env_file.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = value


def load_pipeline_ini(path: Path) -> configparser.ConfigParser:
    cfg = configparser.ConfigParser(interpolation=None)
    cfg.read(path, encoding="utf-8")
    return cfg


def ini_value(cfg: configparser.ConfigParser, section: str, option: str, fallback: str = "") -> str:
    try:
        return cfg.get(section, option, fallback=fallback).strip()
    except Exception:
        return fallback


def first_nonempty(cfg: configparser.ConfigParser, candidates, fallback: str = "") -> str:
    for section, option in candidates:
        value = ini_value(cfg, section, option, "")
        if value:
            return value
    return fallback


def read_prompt(args):
    if args.prompt.strip():
        return args.prompt.strip()

    if not sys.stdin.isatty():
        piped = sys.stdin.read().strip()
        if piped:
            return piped

    return ""


def main():
    args = parse_args()

    root_dir = Path(__file__).resolve().parent.parent
    pipeline_ini = root_dir / "config" / "pipeline.ini"
    cfg = load_pipeline_ini(pipeline_ini)

    load_env_file(args.env_file)

    api_key = os.getenv(
        "GEMINI_API_KEY",
        first_nonempty(cfg, [("api_keys", "gemini_api_key")], ""),
    ).strip()
    if not api_key:
        print(
            "Error: GEMINI_API_KEY is not set. Configure it in config/pipeline.ini [api_keys] gemini_api_key",
            file=sys.stderr,
        )
        sys.exit(1)

    model_name = (
        args.model.strip()
        or os.getenv("GEMINI_MODEL", "").strip()
        or first_nonempty(cfg, [("models", "gemini_model")], "gemini-1.5-flash")
    )

    prompt = read_prompt(args)
    if not prompt:
        print("Error: provide a prompt or pipe one via stdin.", file=sys.stderr)
        sys.exit(1)

    try:
        import google.generativeai as genai
    except Exception as exc:
        print("Error: missing dependency google-generativeai.", file=sys.stderr)
        print("Tip: run setup/install_all.sh", file=sys.stderr)
        raise SystemExit(1) from exc

    genai.configure(api_key=api_key)
    model = genai.GenerativeModel(model_name)

    final_prompt = prompt
    if args.system.strip():
        final_prompt = f"Sistema: {args.system.strip()}\\n\\nUsuario: {prompt}"

    response = model.generate_content(final_prompt)
    output = getattr(response, "text", "").strip()
    if not output:
        print("Error: empty response from Gemini.", file=sys.stderr)
        sys.exit(2)

    print(output)


if __name__ == "__main__":
    main()
