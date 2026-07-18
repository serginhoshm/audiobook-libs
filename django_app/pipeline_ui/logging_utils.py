from __future__ import annotations

from django.utils import timezone


def log_timestamp_string() -> str:
    return timezone.localtime(timezone.now()).strftime("%Y-%m-%d %H:%M:%S")


def format_timestamped_message(message: str) -> str:
    cleaned = str(message).rstrip("\n")
    return f"[{log_timestamp_string()}] {cleaned}"


class TimestampedWriter:
    def __init__(self, fh):
        self._fh = fh

    def write(self, message: str) -> int:
        text = str(message)
        if not text:
            return 0

        has_trailing_newline = text.endswith("\n")
        lines = text.splitlines()

        if not lines:
            self._fh.write(f"[{log_timestamp_string()}]\n")
            return 1

        written = 0
        for idx, line in enumerate(lines):
            self._fh.write(format_timestamped_message(line))
            if idx < len(lines) - 1 or has_trailing_newline:
                self._fh.write("\n")
            written += 1
        return written

    def flush(self) -> None:
        self._fh.flush()
