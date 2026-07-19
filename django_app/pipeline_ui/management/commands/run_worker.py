import fcntl
import os
from pathlib import Path
import time

from django.conf import settings
from django.core.management.base import BaseCommand, CommandError
from django.db import OperationalError
from django.db import transaction
from django.db.models import Q
from django.utils import timezone

from pipeline_ui.logging_utils import format_timestamped_message
from pipeline_ui.models import PipelineRun
from pipeline_ui.runner import (
    PIPELINE_STEP_ORDER,
    _next_pending_step_name,
    _persist_download_result,
    execute_run,
    request_stop,
)
from pipeline_ui.services import (
    WORKER_SCOPE_GENERAL,
    ensure_worker_running,
    resolve_asset_video_path,
    worker_max_slots_per_scope,
)


class Command(BaseCommand):
    help = "Run local worker to consume queued runs"

    def _log(self, message: str, style=None) -> None:
        payload = format_timestamped_message(message)
        if style is not None:
            self.stdout.write(style(payload))
            return
        self.stdout.write(payload)

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
        requested_scope = str(options.get("scope") or WORKER_SCOPE_GENERAL).strip().lower() or WORKER_SCOPE_GENERAL
        requested_slot = max(1, int(options.get("slot") or 1))
        max_slots = worker_max_slots_per_scope()
        supported_scopes = {WORKER_SCOPE_GENERAL, *PIPELINE_STEP_ORDER}

        if requested_scope not in supported_scopes:
            valid = ", ".join(sorted(supported_scopes))
            raise CommandError(f"Unsupported worker scope '{requested_scope}'. Expected one of: {valid}")
        if requested_slot > max_slots:
            raise CommandError(f"Invalid slot={requested_slot}. Supported range is 1..{max_slots}")

        self.scope = requested_scope
        self.slot = requested_slot

        lock_handle = self._acquire_singleton_lock()
        if lock_handle is None:
            self._log(
                f"[worker:{self.scope}:{self.slot}] another matching run_worker instance is already active; exiting",
                style=self.style.WARNING,
            )
            return

        poll_seconds = int(settings.WEBAPP["WORKER_POLL_SECONDS"])
        idle_exit_seconds = int(settings.WEBAPP.get("WORKER_IDLE_EXIT_SECONDS", 180))
        idle_started_at = time.monotonic()

        self._write_pid_file()
        self._log(f"[worker:{self.scope}:{self.slot}] started", style=self.style.SUCCESS)
        self._with_db_retry(self._reconcile_inflight_runs)

        try:
            while True:
                self._with_db_retry(self._reconcile_inflight_runs)
                if self.scope == WORKER_SCOPE_GENERAL:
                    run = self._with_db_retry(self._next_queued_run)
                else:
                    run = self._with_db_retry(lambda: self._next_run_for_step(self.scope))
                if run is None:
                    self._with_db_retry(self._sync_stop_requests)
                    if idle_exit_seconds > 0 and (time.monotonic() - idle_started_at) >= idle_exit_seconds:
                        self._log(f"[worker] idle timeout reached ({idle_exit_seconds}s); exiting")
                        break
                    time.sleep(poll_seconds)
                    continue

                idle_started_at = time.monotonic()

                self._log(
                    f"[worker:{self.scope}:{self.slot}] processing run id={run.id} "
                    f"mode={run.run_mode} video={run.video_asset.file_name}"
                )
                try:
                    execute_run(run)
                except Exception as exc:
                    self._mark_run_failed(run, f"Worker internal error: {exc}")
                finally:
                    ensure_worker_running()
                    pass
        except KeyboardInterrupt:
            self._log(f"[worker:{self.scope}:{self.slot}] shutting down...")
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
                self._log(
                    f"[worker] sqlite lock detected; retrying in {wait_seconds:.2f}s (attempt {attempt}/{attempts})",
                    style=self.style.WARNING,
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
        running_like = (
            PipelineRun.objects.select_related("video_asset")
            .prefetch_related("steps")
            .filter(Q(status__in=["running", "stopping"]) | Q(status="queued", steps__status="running"))
            .distinct()
        )
        for run in running_like:
            has_running_step = any(step.status == "running" for step in run.steps.all())

            # Heal inconsistent state: a step is running but the run was left queued.
            if run.status == "queued" and has_running_step and self._run_process_is_alive(run):
                run.status = "running"
                run.save(update_fields=["status", "updated_at"])
                continue

            if self._run_process_is_alive(run):
                continue

            if run.status == "running" and run.started_at is not None:
                handoff_grace = max(10, int(settings.WEBAPP.get("WORKER_GRACE_SECONDS", 8)) + 2)
                running_for = (timezone.now() - run.started_at).total_seconds()
                if running_for < handoff_grace:
                    continue

            download_step = run.steps.filter(step_name="download").first()
            video_path = resolve_asset_video_path(run.video_asset)
            next_step = _next_pending_step_name(run)
            can_requeue_from_download = (
                download_step is not None
                and not has_running_step
                and run.video_asset.source_url
                and video_path.exists()
                and next_step == "download"
            )
            if can_requeue_from_download:
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
                        now = timezone.now()
                        if download_step.started_at is None:
                            download_step.started_at = now
                        if download_step.finished_at is None:
                            download_step.finished_at = now
                        download_step.save(update_fields=["status", "detail", "started_at", "finished_at", "updated_at"])
                    continue

            if run.process_group_id:
                request_stop(run)

            now = timezone.now()
            for step in run.steps.all():
                if step.status not in {"pending", "running"}:
                    continue
                step.status = "failed"
                if not step.detail:
                    step.detail = "Run reconciled after worker restart"
                if step.started_at is None:
                    step.started_at = now
                if step.finished_at is None:
                    step.finished_at = now
                step.save(update_fields=["status", "detail", "started_at", "finished_at", "updated_at"])

            run.status = "failed"
            run.finished_at = now
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

    def _next_run_for_step(self, step_name: str):
        with transaction.atomic():
            queued_runs = (
                PipelineRun.objects.select_related("video_asset", "video_asset__execution_profile")
                .filter(status="queued")
                .prefetch_related("steps")
                .order_by("created_at", "id")
            )

            for queued_run in queued_runs:
                next_step = _next_pending_step_name(queued_run)
                if next_step != step_name:
                    continue

                claimed = PipelineRun.objects.filter(id=queued_run.id, status="queued").update(status="running")
                if claimed:
                    queued_run.status = "running"
                    return queued_run
        return None

    def _sync_stop_requests(self):
        running = PipelineRun.objects.filter(status="stopping").exclude(process_group_id__isnull=True)
        for run in running:
            request_stop(run)
