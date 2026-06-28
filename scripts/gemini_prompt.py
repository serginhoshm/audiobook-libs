#!/usr/bin/env python3

import argparse
import os
import sys
from pathlib import Path


def parse_args():
    parser = argparse.ArgumentParser(
        description="Executa um prompt geral usando Google Gemini API."
    )
    parser.add_argument(
        "prompt",
        nargs="?",
        default="",
        help="Prompt em linha unica. Se vazio, le de stdin.",
    )
    parser.add_argument(
        "--model",
        default=os.getenv("GEMINI_MODEL", "gemini-1.5-flash"),
        help="Modelo Gemini a ser utilizado.",
    )
    parser.add_argument(
        "--env-file",
        type=Path,
        default=Path("config/translation/gemini.env"),
        help="Arquivo local com GEMINI_API_KEY.",
    )
    parser.add_argument(
        "--system",
        default="",
        help="Instrucao de sistema opcional para guiar o modelo.",
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
    load_env_file(args.env_file)

    api_key = os.getenv("GEMINI_API_KEY", "").strip()
    if not api_key:
        print(
            "Erro: GEMINI_API_KEY nao definida. Configure em config/translation/gemini.env",
            file=sys.stderr,
        )
        sys.exit(1)

    prompt = read_prompt(args)
    if not prompt:
        print("Erro: informe um prompt ou envie via stdin.", file=sys.stderr)
        sys.exit(1)

    try:
        import google.generativeai as genai
    except Exception as exc:
        print("Erro: dependencia google-generativeai ausente.", file=sys.stderr)
        print("Dica: rode setup/install_all.sh", file=sys.stderr)
        raise SystemExit(1) from exc

    genai.configure(api_key=api_key)
    model = genai.GenerativeModel(args.model)

    final_prompt = prompt
    if args.system.strip():
        final_prompt = f"Sistema: {args.system.strip()}\\n\\nUsuario: {prompt}"

    response = model.generate_content(final_prompt)
    output = getattr(response, "text", "").strip()
    if not output:
        print("Erro: resposta vazia do Gemini.", file=sys.stderr)
        sys.exit(2)

    print(output)


if __name__ == "__main__":
    main()
