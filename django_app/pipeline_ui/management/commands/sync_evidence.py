from django.core.management.base import BaseCommand

from pipeline_ui.services import run_evidence_worker


class Command(BaseCommand):
    help = "Reconcilia evidencia de artefatos em disco com os passos gravados no banco"

    def add_arguments(self, parser):
        parser.add_argument("--video-id", dest="video_ids", action="append", type=int)
        parser.add_argument("--video-path", dest="video_paths", action="append")
        parser.add_argument("--housekeeping", action="store_true")

    def handle(self, *args, **options):
        result = run_evidence_worker(
            video_ids=options.get("video_ids") or None,
            video_paths=options.get("video_paths") or None,
            include_housekeeping=bool(options.get("housekeeping")),
        )
        self.stdout.write(
            self.style.SUCCESS(
                "[sync_evidence] concluido synced=%s missing=%s"
                % (result.get("synced", 0), result.get("missing", 0))
            )
        )
