import os
import signal
import time

from django.conf import settings
from django.core.management.base import BaseCommand
from django.utils import timezone

from pipeline_ui.models import PipelineRun


ACTIVE_STATUSES = ["queued", "running", "stopping"]


def _terminate_process_group(pgid: int, grace_seconds: int) -> None:
    try:
        os.killpg(pgid, signal.SIGTERM)
    except ProcessLookupError:
        return

    deadline = time.time() + max(0, grace_seconds)
    while time.time() < deadline:
        try:
            os.killpg(pgid, 0)
        except ProcessLookupError:
            return
        time.sleep(0.25)

    try:
        os.killpg(pgid, signal.SIGKILL)
    except ProcessLookupError:
        return


class Command(BaseCommand):
    help = "Interrompe runs ativos e atualiza o estado no banco durante o stop da webapp"

    def handle(self, *args, **options):
        grace_seconds = int(settings.WEBAPP.get("WORKER_GRACE_SECONDS", 10))
        now = timezone.now()

        runs = list(PipelineRun.objects.filter(status__in=ACTIVE_STATUSES).prefetch_related("steps"))
        stopped_count = 0

        for run in runs:
            if run.process_group_id:
                _terminate_process_group(run.process_group_id, grace_seconds)

            for step in run.steps.all():
                if step.status in {"pending", "running"}:
                    step.status = "skipped"
                    step.detail = "Interrompido durante stop da webapp"
                    step.save(update_fields=["status", "detail", "updated_at"])

            run.stop_requested = True
            run.status = "stopped"
            run.finished_at = now
            run.pid = None
            run.process_group_id = None
            if run.exit_code is None:
                run.exit_code = -15
            run.error_message = "Run interrompida durante stop da webapp"
            run.save(
                update_fields=[
                    "stop_requested",
                    "status",
                    "finished_at",
                    "pid",
                    "process_group_id",
                    "exit_code",
                    "error_message",
                    "updated_at",
                ]
            )
            stopped_count += 1

        self.stdout.write(self.style.SUCCESS(f"[stop_active_runs] runs interrompidos: {stopped_count}"))
