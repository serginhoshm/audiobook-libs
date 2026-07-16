import fcntl
import os
from pathlib import Path
import signal
import time

from django.conf import settings
from django.core.management.base import BaseCommand
from django.db import OperationalError
from django.db import transaction
from django.utils import timezone

from pipeline_ui.models import PipelineRun
from pipeline_ui.runner import (
    _next_pending_step_name,
    _persist_download_result,
    execute_run,
    request_stop,
)
from pipeline_ui.services import resolve_asset_video_path


class Command(BaseCommand):
    help = "Run local worker to consume queued runs"

    def add_arguments(self, parser):
        parser.add_argument("--scope", default="general")
        parser.add_argument("--slot", type=int, default=1)

    def _worker_suffix(self) -> str:
        scope = getattr(self, "scope", "general")
        slot = getattr(self, "slot", 1)
        if scope == "general" and slot == 1:
            return "worker"
        return f"worker-{scope}-{slot}"

    def _worker_run_dir(self) -> Path:
        root = Path(settings.WEBAPP["ROOT_DIR"])
        return root / ".run" / "webapp"

    def _worker_pid_file(self) -> Path:
        return self._worker_run_dir() / f"{self._worker_suffix()}.pid"

    # Legacy LibreTranslate lifecycle helpers are intentionally disabled.
    # Keep this code for future reactivation if local LT orchestration returns.
    # def _libretranslate_url(self) -> str:
    #     return str(settings.WEBAPP.get("LIBRETRANSLATE_URL", "http://127.0.0.1:5000")).rstrip("/")

    # def _libretranslate_is_ready(self) -> bool:
    #     try:
    #         with urlrequest.urlopen(f"{self._libretranslate_url()}/languages", timeout=2) as resp:
    #             return int(getattr(resp, "status", 200)) < 400
    #     except Exception:
    #         return False

    # def _resolve_libretranslate_executable(self) -> Path:
    #     root = Path(settings.WEBAPP["ROOT_DIR"])
    #     configured = str(settings.WEBAPP.get("LIBRETRANSLATE_EXECUTABLE", "")).strip()
    #     if configured:
    #         return Path(configured)
    #     return root / "external" / "LibreTranslate" / ".venv" / "bin" / "libretranslate"

    # def _start_libretranslate_for_run(self) -> tuple[subprocess.Popen | None, str]:
    #     if self._libretranslate_is_ready():
    #         return None, "[worker] libretranslate already ready"
    #
    #     executable = self._resolve_libretranslate_executable()
    #     if not executable.exists():
    #         raise RuntimeError(
    #             f"LibreTranslate executable not found: {executable}. "
    #             "Run: bash setup/libretranslate/setup_libretranslate.sh"
    #         )
    #
    #     load_only = str(settings.WEBAPP.get("LIBRETRANSLATE_LOAD_ONLY_LANG_CODES", "en,es,zh,pt")).strip()
    #     start_timeout = int(settings.WEBAPP.get("LIBRETRANSLATE_START_TIMEOUT_SECONDS", 60))
    #     host = str(settings.WEBAPP.get("LIBRETRANSLATE_HOST", "127.0.0.1")).strip() or "127.0.0.1"
    #     port = str(settings.WEBAPP.get("LIBRETRANSLATE_PORT", "5000")).strip() or "5000"
    #
    #     command = [str(executable), "--host", host, "--port", port]
    #     if load_only:
    #         command.extend(["--load-only", load_only])
    #
    #     proc = subprocess.Popen(
    #         command,
    #         stdout=subprocess.DEVNULL,
    #         stderr=subprocess.DEVNULL,
    #         start_new_session=True,
    #     )
    #
    #     for _ in range(max(1, start_timeout)):
    #         if self._libretranslate_is_ready():
    #             return proc, "[worker] libretranslate started for run"
    #         time.sleep(1)
    #
    #     try:
    #         os.killpg(proc.pid, signal.SIGTERM)
    #     except Exception:
    #         pass
    #     raise RuntimeError("LibreTranslate server did not become ready in time")

    # def _stop_libretranslate_for_run(self, proc: subprocess.Popen | None) -> None:
    #     if proc is None:
    #         return
    #
    #     try:
    #         os.killpg(proc.pid, signal.SIGTERM)
    #     except Exception:
    #         return
    #
    #     for _ in range(8):
    #         if proc.poll() is not None:
    #             return
    #         time.sleep(0.5)
    #
    #     try:
    #         os.killpg(proc.pid, signal.SIGKILL)
    #     except Exception:
    #         return

    def _write_pid_file(self) -> None:
        run_dir = self._worker_run_dir()
        run_dir.mkdir(parents=True, exist_ok=True)
        self._worker_pid_file().write_text(f"{os.getpid()}\n", encoding="utf-8")

    def _cleanup_pid_file(self) -> None:
        pid_file = self._worker_pid_file()
        if not pid_file.exists():
            return
        try:
            current = pid_file.read_text(encoding="utf-8").strip()
            if current == str(os.getpid()):
                pid_file.unlink(missing_ok=True)
        except Exception:
            return

    def _worker_lock_file(self) -> Path:
        return self._worker_run_dir() / f"{self._worker_suffix()}.lock"

    def _acquire_singleton_lock(self):
        lock_file = self._worker_lock_file()
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

    def handle(self, *args, **options):
        requested_scope = str(options.get("scope") or "general")
        requested_slot = max(1, int(options.get("slot") or 1))

        # Backward compatibility with older command lines that passed
        # step-scoped worker options. Sequential mode always runs one worker.
        if requested_scope != "general":
            self.stdout.write(
                self.style.WARNING(
                    f"[worker] ignoring legacy scope '{requested_scope}' and using scope=general"
                )
            )
        if requested_slot != 1:
            self.stdout.write(
                self.style.WARNING(
                    f"[worker] ignoring legacy slot '{requested_slot}' and using slot=1"
                )
            )

        self.scope = "general"
        self.slot = 1

        lock_handle = self._acquire_singleton_lock()
        if lock_handle is None:
            self.stdout.write(
                self.style.WARNING(
                    f"[worker:{self.scope}:{self.slot}] another matching run_worker instance is already active; exiting"
                )
            )
            return

        poll_seconds = int(settings.WEBAPP["WORKER_POLL_SECONDS"])
        idle_exit_seconds = int(settings.WEBAPP.get("WORKER_IDLE_EXIT_SECONDS", 180))
        manage_libretranslate = False
        # To re-enable legacy auto-management:
        # manage_libretranslate = str(settings.WEBAPP.get("WORKER_MANAGE_LIBRETRANSLATE", "1")).strip() != "0"
        idle_started_at = time.monotonic()

        self._write_pid_file()
        self.stdout.write(self.style.SUCCESS(f"[worker:{self.scope}:{self.slot}] started"))
        self._with_db_retry(self._reconcile_inflight_runs)

        try:
            while True:
                self._with_db_retry(self._reconcile_inflight_runs)
                run = self._with_db_retry(self._next_queued_run)
                if run is None:
                    self._with_db_retry(self._sync_stop_requests)
                    if idle_exit_seconds > 0 and (time.monotonic() - idle_started_at) >= idle_exit_seconds:
                        self.stdout.write(f"[worker] idle timeout reached ({idle_exit_seconds}s); exiting")
                        break
                    time.sleep(poll_seconds)
                    continue

                idle_started_at = time.monotonic()

                self.stdout.write(
                    f"[worker:{self.scope}:{self.slot}] processing run id={run.id} "
                    f"mode={run.run_mode} video={run.video_asset.file_name}"
                )
                try:
                    # if manage_libretranslate:
                    #     lt_proc, message = self._start_libretranslate_for_run()
                    #     self.stdout.write(message)
                    execute_run(run)
                except Exception as exc:
                    self._mark_run_failed(run, f"Worker internal error: {exc}")
                finally:
                    # if manage_libretranslate:
                    #     self._stop_libretranslate_for_run(lt_proc)
                    pass
        except KeyboardInterrupt:
            self.stdout.write(f"[worker:{self.scope}:{self.slot}] shutting down...")
        finally:
            self._cleanup_pid_file()
            try:
                lock_handle.close()
            except Exception:
                pass

    def _with_db_retry(self, fn):
        attempts = int(settings.WEBAPP.get("SQLITE_LOCK_RETRY_ATTEMPTS", 5))
        base_wait = float(settings.WEBAPP.get("SQLITE_LOCK_RETRY_WAIT_SECONDS", 0.25))
        for attempt in range(1, attempts + 1):
            try:
                return fn()
            except OperationalError as exc:
                if "database is locked" not in str(exc).lower() or attempt == attempts:
                    raise
                wait_seconds = base_wait * attempt
                self.stdout.write(
                    self.style.WARNING(
                        f"[worker] sqlite lock detected; retrying in {wait_seconds:.2f}s (attempt {attempt}/{attempts})"
                    )
                )
                time.sleep(wait_seconds)

    def _run_process_is_alive(self, run: PipelineRun) -> bool:
        if not run.pid:
            return False
        try:
            os.kill(run.pid, 0)
            return True
        except Exception:
            return False

    def _mark_run_failed(self, run, message: str):
        def _update():
            run.refresh_from_db()
            run.status = "failed"
            run.error_message = message
            run.save(update_fields=["status", "error_message", "updated_at"])

        self._with_db_retry(_update)

    def _reconcile_inflight_runs(self):
        running_like = PipelineRun.objects.select_related("video_asset").filter(status__in=["running", "stopping"])
        for run in running_like:
            if self._run_process_is_alive(run):
                continue

            if run.status == "running" and run.started_at is not None:
                handoff_grace = max(10, int(settings.WEBAPP.get("WORKER_GRACE_SECONDS", 8)) + 2)
                running_for = (timezone.now() - run.started_at).total_seconds()
                if running_for < handoff_grace:
                    continue

            download_step = run.steps.filter(step_name="download").first()
            video_path = resolve_asset_video_path(run.video_asset)
            if download_step and run.video_asset.source_url and video_path.exists():
                try:
                    ok, detail = _persist_download_result(run, video_path)
                except Exception:
                    ok, detail = False, "Download validation failed after restart"

                if ok:
                    run.status = "queued"
                    run.pid = None
                    run.process_group_id = None
                    run.exit_code = None
                    run.error_message = ""
                    run.save(update_fields=["status", "pid", "process_group_id", "exit_code", "error_message", "updated_at"])
                    if download_step.status != "success" or download_step.detail != detail:
                        download_step.status = "success"
                        download_step.detail = detail
                        download_step.save(update_fields=["status", "detail", "updated_at"])
                    continue

            if run.process_group_id:
                request_stop(run)
            run.status = "failed"
            run.finished_at = timezone.now()
            if not run.error_message:
                run.error_message = "Run reconciled after worker restart"
            run.pid = None
            run.process_group_id = None
            run.exit_code = run.exit_code if run.exit_code is not None else -100
            run.save(update_fields=[
                "status",
                "finished_at",
                "error_message",
                "pid",
                "process_group_id",
                "exit_code",
                "updated_at",
            ])

    def _next_queued_run(self):
        with transaction.atomic():
            next_run = (
                PipelineRun.objects.select_related("video_asset", "video_asset__execution_profile")
                .filter(status="queued")
                .prefetch_related("steps")
                .order_by("created_at", "id")
                .first()
            )

            if next_run is None:
                return None

            claimed = PipelineRun.objects.filter(id=next_run.id, status="queued").update(status="running")
            if claimed:
                next_run.status = "running"
                return next_run
        return None

    def _sync_stop_requests(self):
        running = PipelineRun.objects.filter(status="stopping").exclude(process_group_id__isnull=True)
        for run in running:
            request_stop(run)
