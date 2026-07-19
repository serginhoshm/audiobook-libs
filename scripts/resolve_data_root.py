#!/usr/bin/env python3

from __future__ import annotations

import configparser
import sys
from pathlib import Path


def _project_root() -> Path:
    return Path(__file__).resolve().parent.parent


def _load_data_root() -> Path:
    root_dir = _project_root()
    cfg = configparser.ConfigParser(interpolation=None)
    cfg.read(root_dir / "config" / "pipeline.ini", encoding="utf-8")
    raw = cfg.get("paths", "workdir", fallback="").strip()
    if not raw:
        raw = cfg.get("paths", "data_root_relative", fallback="data").strip()
        print(
            "[config] warning: [paths] data_root_relative is deprecated; use [paths] workdir",
            file=sys.stderr,
        )
    if raw.startswith("/"):
        return Path(raw)
    return root_dir / raw


def main() -> int:
    kind = (sys.argv[1] if len(sys.argv) > 1 else "data-root").strip().lower()
    data_root = _load_data_root()

    if kind == "data-root":
        print(data_root)
        return 0
    if kind == "logs-dir":
        print(data_root / "logs")
        return 0
    if kind == "webapp-logs-dir":
        print(data_root / "logs" / "webapp")
        return 0

    print(f"Unsupported kind: {kind}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
