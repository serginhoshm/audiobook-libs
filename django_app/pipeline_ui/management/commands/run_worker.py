import time

from django.conf import settings
from django.core.management.base import BaseCommand
from django.db import transaction
from django.utils import timezone

from pipeline_ui.models import PipelineRun
from pipeline_ui.runner import execute_run, request_stop


class Command(BaseCommand):
    help = "Executa worker local para consumir runs em fila"

    def handle(self, *args, **options):
        poll_seconds = int(settings.WEBAPP["WORKER_POLL_SECONDS"])
        self.stdout.write(self.style.SUCCESS("[worker] iniciado"))
        self._reconcile_inflight_runs()

        try:
            while True:
                self._reconcile_inflight_runs()
                run = self._next_queued_run()
                if run is None:
                    self._sync_stop_requests()
                    time.sleep(poll_seconds)
                    continue

                self.stdout.write(
                    f"[worker] processando run id={run.id} mode={run.run_mode} video={run.video_asset.file_name}"
                )
                try:
                    execute_run(run)
                except Exception as exc:
                    run.refresh_from_db()
                    run.status = "failed"
                    run.error_message = f"Erro interno do worker: {exc}"
                    run.save(update_fields=["status", "error_message", "updated_at"])
        except KeyboardInterrupt:
            self.stdout.write("[worker] encerrando...")

    def _reconcile_inflight_runs(self):
        running_like = PipelineRun.objects.filter(status__in=["running", "stopping"])
        for run in running_like:
            if run.process_group_id:
                request_stop(run)
            run.status = "failed"
            run.finished_at = timezone.now()
            if not run.error_message:
                run.error_message = "Run reconciliada apos reinicio do worker"
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
            run = (
                PipelineRun.objects.select_related("video_asset", "video_asset__execution_profile")
                .filter(status="queued")
                .order_by("created_at")
                .first()
            )
            if run is None:
                return None

            claimed = PipelineRun.objects.filter(id=run.id, status="queued").update(status="running")
            if claimed:
                run.status = "running"
                return run
        return None

    def _sync_stop_requests(self):
        running = PipelineRun.objects.filter(status="stopping").exclude(process_group_id__isnull=True)
        for run in running:
            request_stop(run)
