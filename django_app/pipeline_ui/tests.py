from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

from django.test import TestCase

from .models import PipelineRun, VideoAsset
from .services import (
    _refresh_plex_posters_for_library_asset,
    queue_runs,
    refresh_youtube_title_fields,
    restore_assets,
    sync_run_steps_with_artifacts,
)


class RunLifecycleRulesTests(TestCase):
    def test_restore_creates_current_run_and_queue_reuses_it(self) -> None:
        with TemporaryDirectory() as library_dir, TemporaryDirectory() as exec_dir:
            library_path = Path(library_dir)
            exec_path = Path(exec_dir)

            asset = VideoAsset.objects.create(
                file_path="sample.mp4",
                file_name="sample.mp4",
                storage_location="library",
                is_present=True,
            )
            (library_path / asset.file_name).write_text("video", encoding="utf-8")

            PipelineRun.objects.create(
                video_asset=asset,
                run_mode="pipeline",
                status="success",
            )

            with (
                patch("pipeline_ui.services.load_library_dir", return_value=library_path),
                patch("pipeline_ui.services.load_work_exec_dir", return_value=exec_path),
            ):
                restored = restore_assets([asset.id])

                self.assertEqual(restored, 1)
                self.assertTrue((exec_path / asset.file_name).exists())
                self.assertFalse((library_path / asset.file_name).exists())

                runs_after_restore = list(PipelineRun.objects.filter(video_asset=asset, run_mode="pipeline").order_by("id"))
                self.assertEqual(len(runs_after_restore), 2)
                self.assertEqual(runs_after_restore[-1].status, "discovered")

                queue_result = queue_runs([asset.id])

                self.assertEqual(queue_result["queued"], 1)
                self.assertEqual(queue_result["skipped"], 0)

                runs_after_queue = list(PipelineRun.objects.filter(video_asset=asset, run_mode="pipeline").order_by("id"))
                self.assertEqual(len(runs_after_queue), 2)
                self.assertEqual(runs_after_queue[-1].status, "queued")


class RefreshYoutubeTitleFieldsTests(TestCase):
    def test_refresh_updates_existing_library_titles_from_youtube_api(self) -> None:
        asset = VideoAsset.objects.create(
            file_path="library/sample.mp4",
            file_name="sample.mp4",
            source_url="https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            youtube_title_original="Old title",
            youtube_title_pt_br="Título antigo",
            storage_location="library",
            is_present=True,
        )

        with (
            patch("pipeline_ui.services._youtube_metadata_from_api", return_value={"title": "New title", "language": "en"}),
            patch("pipeline_ui.services._translate_title_pt_br", return_value="Novo título"),
            patch(
                "pipeline_ui.services._refresh_plex_posters_for_library_asset",
                return_value={"status": "updated", "detail": "ok", "files": ["sample.jpg", "sample-poster.jpg"]},
            ),
        ):
            result = refresh_youtube_title_fields([asset.id])

        asset.refresh_from_db()

        self.assertEqual(result["refreshed"], 1)
        self.assertEqual(result["skipped"], 0)
        self.assertEqual(result["failed"], 0)
        self.assertEqual(result["plex_generated"], 1)
        self.assertEqual(result["plex_failed"], 0)
        self.assertEqual(result["plex_skipped"], 0)
        self.assertEqual(asset.youtube_title_original, "New title")
        self.assertEqual(asset.youtube_title_pt_br, "Novo título")

    def test_refresh_renames_all_library_artifacts_from_translated_title(self) -> None:
        with TemporaryDirectory() as library_dir:
            library_path = Path(library_dir)

            asset = VideoAsset.objects.create(
                file_path="old-video.mp4",
                file_name="old-video.mp4",
                source_url="https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                youtube_title_original="Old title",
                youtube_title_pt_br="Título antigo",
                storage_location="library",
                is_present=True,
            )

            for file_name in [
                "old-video.mp4",
                "old-video.srt",
                "old-video.pt.wav",
                "old-video (remux).mp4",
            ]:
                (library_path / file_name).write_text(file_name, encoding="utf-8")

            with (
                patch("pipeline_ui.services.load_library_dir", return_value=library_path),
                patch("pipeline_ui.services._youtube_metadata_from_api", return_value={"title": "New original title", "language": "en"}),
                patch("pipeline_ui.services._translate_title_pt_br", return_value="Novo título brasileiro"),
                patch(
                    "pipeline_ui.services._refresh_plex_posters_for_library_asset",
                    return_value={
                        "status": "updated",
                        "detail": "generated stem poster and stem-poster.jpg",
                        "files": ["Novo título brasileiro.jpg", "Novo título brasileiro-poster.jpg"],
                    },
                ),
            ):
                result = refresh_youtube_title_fields([asset.id])

            asset.refresh_from_db()

            self.assertEqual(result["refreshed"], 1)
            self.assertEqual(result["skipped"], 0)
            self.assertEqual(result["failed"], 0)
            self.assertEqual(asset.file_name, "Novo título brasileiro.mp4")
            self.assertEqual(asset.file_path, "Novo título brasileiro.mp4")
            self.assertTrue((library_path / "Novo título brasileiro.mp4").exists())
            self.assertTrue((library_path / "Novo título brasileiro.srt").exists())
            self.assertTrue((library_path / "Novo título brasileiro.pt.wav").exists())
            self.assertTrue((library_path / "Novo título brasileiro (remux).mp4").exists())
            self.assertFalse((library_path / "old-video.mp4").exists())
            self.assertFalse((library_path / "old-video.srt").exists())
            self.assertFalse((library_path / "old-video.pt.wav").exists())
            self.assertFalse((library_path / "old-video (remux).mp4").exists())

    def test_refresh_reports_api_failure_for_youtube_library_item(self) -> None:
        asset = VideoAsset.objects.create(
            file_path="library/sample.mp4",
            file_name="sample.mp4",
            source_url="https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            storage_location="library",
            is_present=True,
        )

        with patch("pipeline_ui.services._youtube_metadata_from_api", side_effect=RuntimeError("boom")):
            result = refresh_youtube_title_fields([asset.id])

        self.assertEqual(result["refreshed"], 0)
        self.assertEqual(result["skipped"], 0)
        self.assertEqual(result["failed"], 1)
        self.assertEqual(result["items"][0]["status"], "failed")
        self.assertIn("metadata unavailable", result["items"][0]["detail"])

    def test_refresh_plex_failure_does_not_fail_title_refresh(self) -> None:
        asset = VideoAsset.objects.create(
            file_path="library/sample.mp4",
            file_name="sample.mp4",
            source_url="https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            youtube_title_original="Old title",
            youtube_title_pt_br="Título antigo",
            storage_location="library",
            is_present=True,
        )

        with (
            patch("pipeline_ui.services._youtube_metadata_from_api", return_value={"title": "New title", "language": "en"}),
            patch("pipeline_ui.services._translate_title_pt_br", return_value="Novo título"),
            patch(
                "pipeline_ui.services._refresh_plex_posters_for_library_asset",
                return_value={"status": "failed", "detail": "conversion failed", "files": []},
            ),
        ):
            result = refresh_youtube_title_fields([asset.id])

        self.assertEqual(result["refreshed"], 1)
        self.assertEqual(result["failed"], 0)
        self.assertEqual(result["plex_generated"], 0)
        self.assertEqual(result["plex_failed"], 1)
        self.assertEqual(result["items"][0]["plex_poster_status"], "failed")


class PlexPosterGenerationTests(TestCase):
    def test_generates_and_overwrites_stem_and_poster_files(self) -> None:
        with TemporaryDirectory() as library_dir:
            library_path = Path(library_dir)
            source_thumb = library_path / "source-thumb.webp"
            source_thumb.write_bytes(b"mock-thumb")

            stem_target = library_path / "video-one.jpg"
            poster_target = library_path / "video-one-poster.jpg"
            stem_target.write_bytes(b"old-stem")
            poster_target.write_bytes(b"old-poster")

            asset = VideoAsset.objects.create(
                file_path="video-one.mp4",
                file_name="video-one.mp4",
                source_url="https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                storage_location="library",
                is_present=True,
            )

            def fake_convert(_source: Path, destination: Path) -> None:
                destination.write_bytes(f"new:{destination.name}".encode("utf-8"))

            with (
                patch("pipeline_ui.services.load_library_dir", return_value=library_path),
                patch("pipeline_ui.services._download_best_thumbnail_for_asset", return_value=source_thumb),
                patch("pipeline_ui.services._convert_image_to_jpeg", side_effect=fake_convert),
            ):
                result = _refresh_plex_posters_for_library_asset(asset, metadata={"thumbnail": "https://example/thumb.webp"})

            self.assertEqual(result["status"], "updated")
            self.assertEqual(result["files"], ["video-one.jpg", "video-one-poster.jpg"])
            self.assertEqual(stem_target.read_bytes(), b"new:video-one.jpg")
            self.assertEqual(poster_target.read_bytes(), b"new:video-one-poster.jpg")

    def test_returns_failed_when_thumbnail_is_unavailable(self) -> None:
        with TemporaryDirectory() as library_dir:
            library_path = Path(library_dir)
            asset = VideoAsset.objects.create(
                file_path="video-two.mp4",
                file_name="video-two.mp4",
                source_url="https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                storage_location="library",
                is_present=True,
            )

            with (
                patch("pipeline_ui.services.load_library_dir", return_value=library_path),
                patch("pipeline_ui.services._download_best_thumbnail_for_asset", return_value=None),
            ):
                result = _refresh_plex_posters_for_library_asset(asset, metadata={})

            self.assertEqual(result["status"], "failed")
            self.assertIn("thumbnail unavailable", result["detail"])


class ScanDeepValidationTests(TestCase):
    def _write_srt(self, path: Path, end_timestamp: str) -> None:
        text = (
            "1\n"
            "00:00:00,000 --> 00:00:10,000\n"
            "Line one\n\n"
            f"2\n00:00:10,000 --> {end_timestamp}\n"
            "Line two\n"
        )
        path.write_text(text, encoding="utf-8")

    def test_scan_keeps_transcribe_pending_when_srt_coverage_is_insufficient(self) -> None:
        with TemporaryDirectory() as exec_dir, TemporaryDirectory() as remux_dir:
            exec_path = Path(exec_dir)
            remux_path = Path(remux_dir)

            asset = VideoAsset.objects.create(
                file_path="asset-one.mp4",
                file_name="asset-one.mp4",
                source_url="https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                source_duration_seconds=120.0,
                original_language="es",
                storage_location="exec",
                is_present=True,
                is_deleted=False,
            )

            video_path = exec_path / "asset-one.mp4"
            srt_path = exec_path / "asset-one.srt"
            video_path.write_bytes(b"video")
            self._write_srt(srt_path, end_timestamp="00:00:20,000")

            def fake_ffprobe(path: Path):
                if path.suffix.lower() == ".mp4":
                    return 120.0
                return None

            with (
                patch("pipeline_ui.services.load_work_exec_dir", return_value=exec_path),
                patch("pipeline_ui.services.load_work_remux_dir", return_value=remux_path),
                patch("pipeline_ui.services.ffprobe_duration_seconds", side_effect=fake_ffprobe),
            ):
                sync_run_steps_with_artifacts(asset)

            run = PipelineRun.objects.filter(video_asset=asset, run_mode="pipeline").first()
            self.assertIsNotNone(run)
            steps = {step.step_name: step.status for step in run.steps.all()}
            self.assertEqual(steps["extract"], "pending")
            self.assertEqual(steps["transcribe"], "pending")
            self.assertEqual(steps["translate"], "pending")

    def test_scan_keeps_translate_pending_when_source_language_is_unresolved(self) -> None:
        with TemporaryDirectory() as exec_dir, TemporaryDirectory() as remux_dir:
            exec_path = Path(exec_dir)
            remux_path = Path(remux_dir)

            asset = VideoAsset.objects.create(
                file_path="asset-two.mp4",
                file_name="asset-two.mp4",
                source_url="https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                source_duration_seconds=120.0,
                original_language="auto",
                storage_location="exec",
                is_present=True,
                is_deleted=False,
            )

            video_path = exec_path / "asset-two.mp4"
            srt_path = exec_path / "asset-two.srt"
            srtpt_path = exec_path / "asset-two.srtpt"
            video_path.write_bytes(b"video")
            self._write_srt(srt_path, end_timestamp="00:00:59,000")
            self._write_srt(srtpt_path, end_timestamp="00:00:59,000")

            def fake_ffprobe(path: Path):
                if path.suffix.lower() == ".mp4":
                    return 60.0
                return None

            with (
                patch("pipeline_ui.services.load_work_exec_dir", return_value=exec_path),
                patch("pipeline_ui.services.load_work_remux_dir", return_value=remux_path),
                patch("pipeline_ui.services.ffprobe_duration_seconds", side_effect=fake_ffprobe),
            ):
                sync_run_steps_with_artifacts(asset)

            run = PipelineRun.objects.filter(video_asset=asset, run_mode="pipeline").first()
            self.assertIsNotNone(run)
            steps = {step.step_name: step.status for step in run.steps.all()}
            self.assertEqual(steps["translate"], "pending")

    def test_scan_keeps_audiobook_pending_when_pt_wav_duration_is_invalid(self) -> None:
        with TemporaryDirectory() as exec_dir, TemporaryDirectory() as remux_dir:
            exec_path = Path(exec_dir)
            remux_path = Path(remux_dir)

            asset = VideoAsset.objects.create(
                file_path="asset-three.mp4",
                file_name="asset-three.mp4",
                source_url="https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                source_duration_seconds=120.0,
                original_language="es",
                storage_location="exec",
                is_present=True,
                is_deleted=False,
            )

            video_path = exec_path / "asset-three.mp4"
            srt_path = exec_path / "asset-three.srt"
            srtpt_path = exec_path / "asset-three.srtpt"
            pt_wav_path = exec_path / "asset-three.pt.wav"
            video_path.write_bytes(b"video")
            pt_wav_path.write_bytes(b"wav")
            self._write_srt(srt_path, end_timestamp="00:00:59,000")
            self._write_srt(srtpt_path, end_timestamp="00:00:59,000")

            def fake_ffprobe(path: Path):
                suffix = path.suffix.lower()
                if suffix == ".mp4":
                    return 60.0
                if path.name.endswith(".pt.wav"):
                    return 40.0
                return None

            with (
                patch("pipeline_ui.services.load_work_exec_dir", return_value=exec_path),
                patch("pipeline_ui.services.load_work_remux_dir", return_value=remux_path),
                patch("pipeline_ui.services.ffprobe_duration_seconds", side_effect=fake_ffprobe),
            ):
                sync_run_steps_with_artifacts(asset)

            run = PipelineRun.objects.filter(video_asset=asset, run_mode="pipeline").first()
            self.assertIsNotNone(run)
            steps = {step.step_name: step.status for step in run.steps.all()}
            self.assertEqual(steps["audiobook"], "pending")
            self.assertEqual(steps["remux"], "pending")