import fcntl
import os
from pathlib import Path
import time

from django.conf import settings
from django.core.management.base import BaseCommand

from pipeline_ui.services import ensure_worker_running


class Command(BaseCommand):
    help = "Run dedicated worker coordinator to keep step-scoped workers active"

    def add_arguments(self, parser):
        parser.add_argument("--poll-seconds", type=int, default=0)
        parser.add_argument("--once", action="store_true")

    def _run_dir(self) -> Path:
        root = Path(settings.WEBAPP["ROOT_DIR"])
        return root / ".run" / "webapp"

    def _pid_file(self) -> Path:
        return self._run_dir() / "coordinator.pid"

    def _lock_file(self) -> Path:
        return self._run_dir() / "coordinator.lock"

    def _acquire_singleton_lock(self):
        lock_file = self._lock_file()
        lock_file.parent.mkdir(parents=True, exist_ok=True)
        handle = open(lock_file, "w", encoding="utf-8")
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            handle.close()
            return None
        handle.write(f"{os.getpid()}\n")
        handle.flush()
        return handle

    def _write_pid_file(self) -> None:
        run_dir = self._run_dir()
        run_dir.mkdir(parents=True, exist_ok=True)
        self._pid_file().write_text(f"{os.getpid()}\n", encoding="utf-8")

    def _cleanup_pid_file(self) -> None:
        pid_file = self._pid_file()
        if not pid_file.exists():
            return
        try:
            current = pid_file.read_text(encoding="utf-8").strip()
            if current == str(os.getpid()):
                pid_file.unlink(missing_ok=True)
        except Exception:
            return

    def handle(self, *args, **options):
        requested_poll = int(options.get("poll_seconds") or 0)
        default_poll = int(settings.WEBAPP.get("COORDINATOR_POLL_SECONDS", 5))
        poll_seconds = max(1, requested_poll if requested_poll > 0 else default_poll)
        run_once = bool(options.get("once"))

        lock_handle = self._acquire_singleton_lock()
        if lock_handle is None:
            self.stdout.write(self.style.WARNING("[coordinator] another instance is already active; exiting"))
            return

        self._write_pid_file()
        self.stdout.write(self.style.SUCCESS(f"[coordinator] started (poll={poll_seconds}s once={run_once})"))

        try:
            while True:
                summary = ensure_worker_running()
                if summary.get("started"):
                    started = summary.get("started_worker_pids") or []
                    self.stdout.write(f"[coordinator] ensured workers: started={started}")
                if run_once:
                    break
                time.sleep(poll_seconds)
        except KeyboardInterrupt:
            self.stdout.write("[coordinator] shutting down...")
        finally:
            self._cleanup_pid_file()
            try:
                lock_handle.close()
            except Exception:
                pass
