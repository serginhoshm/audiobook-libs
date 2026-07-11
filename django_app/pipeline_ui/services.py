import configparser
import json
import os
import re
import subprocess
import sys
import time
import shutil
from urllib.parse import urlparse
from datetime import timedelta
from pathlib import Path
from typing import Any

from django.conf import settings
from django.db import OperationalError
from django.db.models import Q
from django.utils import timezone

from .models import ExecutionProfile, PipelineRun, PipelineStepStatus, VideoAsset


VIDEO_EXTENSIONS = {".mp4", ".mkv"}
PIPELINE_STEP_ORDER = ["download", "extract", "transcribe", "translate", "audiobook", "remux"]
RUN_MODE_PIPELINE = "pipeline"
DOWNLOAD_DURATION_TOLERANCE_SECONDS = 2.5
DOWNLOAD_FORMAT_FILTER = "bv*[height>=480][height<=720]+ba/b[height>=480][height<=720]"


def _with_sqlite_lock_retry(fn, *args, **kwargs):
    attempts = int(settings.WEBAPP.get("SQLITE_LOCK_RETRY_ATTEMPTS", 5))
    base_wait = float(settings.WEBAPP.get("SQLITE_LOCK_RETRY_WAIT_SECONDS", 0.25))

    for attempt in range(1, attempts + 1):
        try:
            return fn(*args, **kwargs)
        except OperationalError as exc:
            if "database is locked" not in str(exc).lower() or attempt == attempts:
                raise
            time.sleep(base_wait * attempt)


def _discover_worker_pids() -> list[int]:
    root = project_root()
    script_hint = str(root / "django_app" / "manage.py")
    try:
        output = subprocess.check_output(
            ["pgrep", "-f", f"{script_hint} run_worker"],
            text=True,
            stderr=subprocess.DEVNULL,
        )
        pids = [int(line.strip()) for line in output.splitlines() if line.strip().isdigit()]
        return sorted(set(pids))
    except Exception:
        return []


def _worker_run_dir() -> Path:
    return project_root() / ".run" / "webapp"


def _worker_pid_file() -> Path:
    return _worker_run_dir() / "worker.pid"


def _worker_log_file() -> Path:
    return Path(settings.WEBAPP["WEBAPP_LOG_DIR"]) / "worker.log"


def _worker_python_executable() -> str:
    root = project_root()
    venv_python = root / ".venv" / "bin" / "python"
    if venv_python.exists():
        return str(venv_python)
    return sys.executable


def _spawn_worker_process() -> int:
    run_dir = _worker_run_dir()
    run_dir.mkdir(parents=True, exist_ok=True)

    log_file = _worker_log_file()
    log_file.parent.mkdir(parents=True, exist_ok=True)

    root = project_root()
    command = [
        _worker_python_executable(),
        str(root / "django_app" / "manage.py"),
        "run_worker",
    ]

    with open(log_file, "a", encoding="utf-8") as out:
        out.write("[webapp] auto-starting worker process\n")

    log_handle = open(log_file, "a", encoding="utf-8")
    proc = subprocess.Popen(
        command,
        cwd=str(root),
        stdout=log_handle,
        stderr=log_handle,
        start_new_session=True,
    )
    log_handle.close()

    _worker_pid_file().write_text(f"{proc.pid}\n", encoding="utf-8")
    return proc.pid


def ensure_worker_running() -> dict[str, Any]:
    discovered_pids = _discover_worker_pids()
    if discovered_pids:
        run_dir = _worker_run_dir()
        run_dir.mkdir(parents=True, exist_ok=True)
        _worker_pid_file().write_text(f"{discovered_pids[0]}\n", encoding="utf-8")
        return {
            "started": False,
            "pid": discovered_pids[0],
            "reason": "already_running_process_scan",
            "worker_pids": discovered_pids,
        }

    status = worker_health_status()
    if status["running"]:
        return {
            "started": False,
            "pid": status["pid"],
            "reason": "already_running",
            "worker_pids": status.get("worker_pids", []),
        }

    pid = _spawn_worker_process()
    return {
        "started": True,
        "pid": pid,
        "reason": "auto_started",
        "worker_pids": [pid],
    }


def project_root() -> Path:
    return Path(settings.WEBAPP["ROOT_DIR"])


def pipeline_config_path() -> Path:
    return Path(settings.WEBAPP["PIPELINE_CONFIG"])


def load_data_root() -> Path:
    cfg = configparser.ConfigParser(interpolation=None)
    cfg.read(pipeline_config_path(), encoding="utf-8")

    raw = cfg.get("paths", "data_root_relative", fallback="data").strip()
    if raw.startswith("/"):
        return Path(raw)
    return project_root() / raw


def load_work_exec_dir() -> Path:
    return load_data_root() / "exec"


def load_done_dir() -> Path:
    return load_data_root() / "done"


def load_download_dir() -> Path:
    return load_work_exec_dir()


def infer_language_from_name(file_name: str) -> str:
    name = file_name.lower()
    if "spanish" in name:
        return "es"
    if "chinese" in name:
        return "zh-CN"
    return "auto"


def infer_language_from_srt(video_path: Path) -> str:
    srt_path = video_path.with_suffix(".srt")
    if not srt_path.exists():
        return infer_language_from_name(video_path.name)

    try:
        text = srt_path.read_text(encoding="utf-8", errors="ignore")
    except Exception:
        return infer_language_from_name(video_path.name)

    han_count = len(re.findall(r"[\u3400-\u9fff\uf900-\ufaff]", text))
    es_hint_count = len(
        re.findall(
            r"\b(el|la|los|las|de|que|por|para|con|una|uno|como|pero|est(?:a|\u00e1)|est(?:a|\u00e1)n|hoy)\b|[\u00bf\u00a1\u00f1\u00e1\u00e9\u00ed\u00f3\u00fa\u00fc]",
            text.lower(),
        )
    )

    if han_count >= 15 and han_count >= (es_hint_count * 0.6):
        return "zh-CN"
    if es_hint_count >= 20:
        return "es"
    return infer_language_from_name(video_path.name)


def ffprobe_duration_seconds(file_path: Path) -> float | None:
    cmd = [
        "ffprobe",
        "-v",
        "error",
        "-show_entries",
        "format=duration",
        "-of",
        "default=noprint_wrappers=1:nokey=1",
        str(file_path),
    ]
    try:
        out = subprocess.check_output(cmd, stderr=subprocess.DEVNULL, text=True).strip()
        if not out:
            return None
        return round(float(out), 3)
    except Exception:
        return None


def _download_date_prefix(now=None) -> str:
    current = now or timezone.now()
    return current.strftime("%Y-%m-%d")


def _yt_dlp_js_runtime_args() -> list[str]:
    for runtime in ("deno", "node"):
        runtime_path = shutil.which(runtime)
        if runtime_path:
            return ["--js-runtimes", f"{runtime}:{runtime_path}"]
    raise RuntimeError(
        "yt-dlp requires a JavaScript runtime for YouTube extraction. "
        "Install deno or node, then try again."
    )


def _next_download_basename(for_date=None) -> str:
    date_prefix = _download_date_prefix(for_date)
    next_number = 1
    existing_numbers: set[int] = set()
    download_dir = load_download_dir()

    if download_dir.exists():
        for candidate in download_dir.iterdir():
            if not candidate.is_file():
                continue
            match = re.fullmatch(rf"{re.escape(date_prefix)}-(\d{{3}})\.mp4", candidate.name)
            if match:
                existing_numbers.add(int(match.group(1)))

    for asset_name in VideoAsset.objects.filter(file_name__startswith=f"{date_prefix}-").values_list("file_name", flat=True):
        match = re.fullmatch(rf"{re.escape(date_prefix)}-(\d{{3}})\.mp4", asset_name)
        if match:
            existing_numbers.add(int(match.group(1)))

    while next_number in existing_numbers:
        next_number += 1

    return f"{date_prefix}-{next_number:03d}"


def _probe_youtube_metadata(url: str) -> dict[str, Any]:
    command = [
        "yt-dlp",
        "--no-playlist",
        "--skip-download",
        "--dump-single-json",
        *_yt_dlp_js_runtime_args(),
        url,
    ]
    try:
        output = subprocess.check_output(command, stderr=subprocess.STDOUT, text=True)
    except subprocess.CalledProcessError as exc:
        detail = (exc.output or "").strip() or str(exc)
        raise RuntimeError(f"yt-dlp failed to read metadata: {detail}") from exc

    try:
        data = json.loads(output)
    except json.JSONDecodeError as exc:
        preview = output.strip().splitlines()[0] if output.strip() else ""
        raise RuntimeError(
            f"yt-dlp returned non-JSON metadata output{': ' + preview if preview else ''}"
        ) from exc

    if not isinstance(data, dict):
        raise RuntimeError("yt-dlp metadata response is invalid")
    return data


def _normalize_download_path(target_name: str) -> Path:
    download_dir = load_download_dir()
    download_dir.mkdir(parents=True, exist_ok=True)
    return download_dir / f"{target_name}.mp4"


def _download_command(source_url: str, target_path: Path) -> list[str]:
    return [
        "yt-dlp",
        "--no-playlist",
        "--continue",
        "--merge-output-format",
        "mp4",
        *_yt_dlp_js_runtime_args(),
        "-f",
        DOWNLOAD_FORMAT_FILTER,
        "-o",
        f"{target_path.with_suffix('')}.%(ext)s",
        source_url,
    ]


def _validate_downloaded_video(asset: VideoAsset, video_path: Path) -> tuple[bool, str]:
    if not video_path.exists():
        return False, "Downloaded MP4 not found"

    local_duration = ffprobe_duration_seconds(video_path)
    if local_duration is None:
        return False, "Unable to read downloaded MP4 duration"

    if asset.source_duration_seconds is None:
        return True, f"Downloaded MP4 present with duration {local_duration:.1f}s"

    delta = abs(local_duration - asset.source_duration_seconds)
    if delta <= DOWNLOAD_DURATION_TOLERANCE_SECONDS:
        return True, (
            "Downloaded MP4 duration matches source duration: "
            f"local {local_duration:.1f}s vs source {asset.source_duration_seconds:.1f}s"
        )

    return False, (
        "Downloaded MP4 duration mismatch: "
        f"local {local_duration:.1f}s vs source {asset.source_duration_seconds:.1f}s"
    )


def queue_download_run(source_url: str) -> dict[str, Any]:
    source_url = str(source_url or "").strip()
    if not source_url:
        raise ValueError("source_url is empty")

    parsed = urlparse(source_url)
    host = parsed.netloc.lower()
    if parsed.scheme not in {"http", "https"} or not host:
        raise ValueError("source_url must be a valid http or https URL")
    if "youtube.com" not in host and "youtu.be" not in host:
        raise ValueError("source_url must point to YouTube")

    metadata = _probe_youtube_metadata(source_url)
    target_base = _next_download_basename()
    target_path = _normalize_download_path(target_base)
    now = timezone.now()

    asset = VideoAsset.objects.create(
        file_path=str(target_path),
        file_name=target_path.name,
        source_url=source_url,
        extension=".mp4",
        size_bytes=0,
        duration_seconds=None,
        source_duration_seconds=float(metadata.get("duration")) if metadata.get("duration") is not None else None,
        original_language="auto",
        discovered_at=now,
        last_seen_at=now,
        is_present=False,
    )
    ensure_execution_profile(asset)

    run = PipelineRun.objects.create(video_asset=asset, run_mode=RUN_MODE_PIPELINE, status="queued")
    for step_name in PIPELINE_STEP_ORDER:
        PipelineStepStatus.objects.create(pipeline_run=run, step_name=step_name, status="pending")

    worker = ensure_worker_running()
    return {
        "asset_id": asset.id,
        "run_id": run.id,
        "target_path": str(target_path),
        "source_duration_seconds": asset.source_duration_seconds,
        "worker": worker,
    }


def ensure_execution_profile(asset: VideoAsset) -> ExecutionProfile:
    profile, _ = ExecutionProfile.objects.get_or_create(video_asset=asset)
    return profile


def artifact_paths_for_asset(asset: VideoAsset) -> dict[str, Path]:
    video_path = Path(asset.file_path)
    done_dir = load_done_dir()
    remux_dir = load_data_root() / "remux"
    done_video_path = done_dir / asset.file_name
    stem_path = video_path.with_suffix("")
    done_stem_path = done_video_path.with_suffix("")

    def _find_remux_evidence_path() -> Path:
        # Exact original filename in done/ remains the highest-confidence signal.
        if done_video_path.exists():
            return done_video_path

        source_stem = video_path.stem.lower()
        source_ext = video_path.suffix.lower()

        for folder in (done_dir, remux_dir):
            if not folder.exists():
                continue
            try:
                for candidate in folder.iterdir():
                    if not candidate.is_file():
                        continue
                    name_lower = candidate.name.lower()
                    if candidate.suffix.lower() != source_ext:
                        continue
                    if source_stem in name_lower and "remux" in name_lower:
                        return candidate
            except Exception:
                continue

        return done_video_path

    def _first_existing(*paths: Path) -> Path:
        for path in paths:
            if path.exists():
                return path
        return paths[0]

    return {
        "video": _first_existing(video_path, done_video_path),
        "wav": _first_existing(stem_path.with_suffix(".wav"), done_stem_path.with_suffix(".wav")),
        "mp3": _first_existing(stem_path.with_suffix(".mp3"), done_stem_path.with_suffix(".mp3")),
        "srt": _first_existing(stem_path.with_suffix(".srt"), done_stem_path.with_suffix(".srt")),
        "srtpt": _first_existing(stem_path.with_suffix(".srtpt"), done_stem_path.with_suffix(".srtpt")),
        "pt_wav": _first_existing(stem_path.with_suffix(".pt.wav"), done_stem_path.with_suffix(".pt.wav")),
        "done_video": _find_remux_evidence_path(),
    }


def step_evidence_for_asset(asset: VideoAsset) -> dict[str, tuple[bool, str]]:
    artifacts = artifact_paths_for_asset(asset)
    has_wav = artifacts["wav"].exists()
    has_mp3 = artifacts["mp3"].exists()
    has_srt = artifacts["srt"].exists()
    has_srtpt = artifacts["srtpt"].exists()
    has_pt_wav = artifacts["pt_wav"].exists()
    has_audio_input = has_wav or has_mp3
    has_download = artifacts["video"].exists()

    download_found = False
    download_detail = "Evidence: downloaded MP4 not found"
    if has_download:
        download_found, download_detail = _validate_downloaded_video(asset, artifacts["video"])
        if not asset.source_url:
            download_detail = "Evidence: MP4 file found"

    return {
        "download": (download_found or (has_download and not asset.source_url), download_detail),
        "extract": (has_audio_input or has_srt or has_srtpt or has_pt_wav, "Evidence: WAV/MP3/SRT artifact found"),
        "transcribe": (has_audio_input or has_srt or has_srtpt or has_pt_wav, "Evidence: WAV/MP3/SRT artifact found"),
        "translate": (has_srtpt or has_pt_wav, "Evidence: .srtpt file found"),
        "audiobook": (has_pt_wav, "Evidence: .pt.wav file found"),
        "remux": (artifacts["done_video"].exists(), "Evidence: final video moved to done"),
    }


def sync_run_steps_with_artifacts(asset: VideoAsset) -> None:
    evidence = step_evidence_for_asset(asset)
    run = latest_run_for_asset(asset, run_mode=RUN_MODE_PIPELINE)
    if run is None and not any(found for found, _ in evidence.values()):
        return

    if run is None:
        run = PipelineRun.objects.create(video_asset=asset, run_mode=RUN_MODE_PIPELINE, status="discovered")

    # Never override step states while a run is in-flight. During execution,
    # worker updates are the source of truth for UI progress.
    if run.status in {"queued", "running", "stopping"}:
        return

    step_changed = False
    for step_name in PIPELINE_STEP_ORDER:
        found, detail = evidence[step_name]
        step, created = PipelineStepStatus.objects.get_or_create(
            pipeline_run=run,
            step_name=step_name,
            defaults={"status": "pending", "detail": ""},
        )

        if step_name == "download" and not asset.source_url and found:
            desired_status = "skipped"
        elif step_name == "download" and found:
            desired_status = "success"
        elif found:
            desired_status = "success"
        else:
            desired_status = "pending"

        if desired_status != "pending" and (created or step.status != desired_status or step.detail != detail):
            step.status = desired_status
            step.detail = detail
            step.save(update_fields=["status", "detail", "updated_at"])
            step_changed = True
        elif (not found) and step.status == "success" and step.detail.startswith("Evidence:"):
            step.status = "pending"
            step.detail = ""
            step.save(update_fields=["status", "detail", "updated_at"])
            step_changed = True

    found_remux = evidence["remux"][0]
    is_active = run.status in {"queued", "running", "stopping"}

    if found_remux and (not is_active) and run.status != "success":
        run.status = "success"
        run.exit_code = 0
        run.error_message = ""
        if not run.finished_at:
            run.finished_at = timezone.now()
        run.save(update_fields=["status", "exit_code", "error_message", "finished_at", "updated_at"])
    elif (not found_remux) and (not is_active) and run.status == "success":
        run.status = "discovered"
        run.exit_code = None
        run.finished_at = None
        run.save(update_fields=["status", "exit_code", "finished_at", "updated_at"])
    elif step_changed:
        run.save(update_fields=["updated_at"])


def scan_videos() -> dict[str, int]:
    work_exec = load_work_exec_dir()
    work_exec.mkdir(parents=True, exist_ok=True)

    now = timezone.now()
    discovered = 0
    updated = 0

    present_paths: set[str] = set()
    for path in sorted(work_exec.iterdir()):
        if not path.is_file() or path.suffix.lower() not in VIDEO_EXTENSIONS:
            continue

        present_paths.add(str(path))
        defaults = {
            "file_name": path.name,
            "extension": path.suffix.lower(),
            "size_bytes": path.stat().st_size,
            "duration_seconds": ffprobe_duration_seconds(path),
            "original_language": infer_language_from_srt(path),
            "discovered_at": now,
            "last_seen_at": now,
            "is_present": True,
        }
        asset, created = _with_sqlite_lock_retry(
            VideoAsset.objects.update_or_create,
            file_path=str(path),
            defaults=defaults,
        )
        _with_sqlite_lock_retry(ensure_execution_profile, asset)
        _with_sqlite_lock_retry(sync_run_steps_with_artifacts, asset)
        if created:
            discovered += 1
        else:
            updated += 1

    missing = 0
    for asset in _with_sqlite_lock_retry(lambda: list(VideoAsset.objects.filter(is_present=True))):
        if asset.file_path not in present_paths:
            asset.is_present = False
            asset.last_seen_at = now
            _with_sqlite_lock_retry(asset.save, update_fields=["is_present", "last_seen_at"])
            missing += 1

    return {"discovered": discovered, "updated": updated, "missing": missing}


def run_evidence_worker(
    video_ids: list[int] | None = None,
    video_paths: list[str] | None = None,
    include_housekeeping: bool = False,
) -> dict[str, int]:
    qs = VideoAsset.objects.all()
    if video_ids:
        qs = qs.filter(id__in=video_ids)

    if video_paths:
        path_set = {str(Path(path)) for path in video_paths}
        file_names = {Path(path).name for path in video_paths}
        qs = qs.filter(Q(file_path__in=path_set) | Q(file_name__in=file_names))

    synced = 0
    for asset in qs:
        sync_run_steps_with_artifacts(asset)
        synced += 1

    missing = 0
    if include_housekeeping:
        now = timezone.now()
        for asset in VideoAsset.objects.filter(is_present=True):
            if not Path(asset.file_path).exists():
                asset.is_present = False
                asset.last_seen_at = now
                asset.save(update_fields=["is_present", "last_seen_at"])
                missing += 1

    return {"synced": synced, "missing": missing}


def worker_health_status() -> dict[str, Any]:
    pid_file = _worker_pid_file()
    discovered_pids = _discover_worker_pids()

    queued = PipelineRun.objects.filter(status="queued").count()
    running = PipelineRun.objects.filter(status="running").count()
    stopping = PipelineRun.objects.filter(status="stopping").count()

    pid = None
    process_running = False
    source = "pid_file"

    if pid_file.exists():
        try:
            raw = pid_file.read_text(encoding="utf-8").strip()
            if raw:
                pid = int(raw)
                os.kill(pid, 0)
                process_running = True
        except Exception:
            process_running = False
    else:
        source = "pid_file_missing"

    return {
        "running": process_running or bool(discovered_pids),
        "pid": pid,
        "source": source,
        "worker_pids": discovered_pids,
        "worker_count": len(discovered_pids),
        "queue": {
            "queued": queued,
            "running": running,
            "stopping": stopping,
        },
    }


def active_run_exists(video_asset_id: int, run_mode: str | None = None) -> bool:
    qs = PipelineRun.objects.filter(video_asset_id=video_asset_id, status__in=["queued", "running", "stopping"])
    if run_mode:
        qs = qs.filter(run_mode=run_mode)
    return qs.exists()


def queue_runs(video_ids: list[int]) -> dict[str, Any]:
    queued_ids = []
    skipped = 0

    for video_id in video_ids:
        if active_run_exists(video_id, run_mode=RUN_MODE_PIPELINE):
            skipped += 1
            continue
        run = PipelineRun.objects.create(video_asset_id=video_id, run_mode=RUN_MODE_PIPELINE, status="queued")
        for step_name in PIPELINE_STEP_ORDER:
            PipelineStepStatus.objects.create(pipeline_run=run, step_name=step_name, status="pending")
        queued_ids.append(run.id)

    worker = None
    if queued_ids:
        worker = ensure_worker_running()

    return {
        "queued": len(queued_ids),
        "skipped": skipped,
        "run_ids": queued_ids,
        "worker": worker,
    }


def queue_download_job(source_url: str) -> dict[str, Any]:
    return queue_download_run(source_url)


def request_stop_for_runs(run_ids: list[int] | None = None, video_ids: list[int] | None = None) -> int:
    qs = PipelineRun.objects.filter(status__in=["queued", "running", "stopping"])
    if run_ids:
        qs = qs.filter(id__in=run_ids)
    if video_ids:
        qs = qs.filter(video_asset_id__in=video_ids)

    count = 0
    for run in qs:
        run.stop_requested = True
        run.status = "stopping"
        run.save(update_fields=["stop_requested", "status", "updated_at"])
        count += 1
    return count


def parse_bool(value: Any, default: bool = False) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    text = str(value).strip().lower()
    return text in {"1", "true", "yes", "on", "sim", "s"}


def update_execution_profile(video_id: int, payload: dict[str, Any]) -> ExecutionProfile:
    asset = VideoAsset.objects.get(id=video_id)
    profile = ensure_execution_profile(asset)

    allowed = {
        "backend",
        "nllb_profile",
        "nllb_max_input_length",
        "nllb_max_new_tokens",
        "nllb_legacy",
        "deepl_endpoint",
    }

    for key in allowed:
        if key not in payload:
            continue
        value = payload[key]
        if key in {"nllb_max_input_length", "nllb_max_new_tokens"}:
            try:
                value = int(value)
            except Exception:
                continue
        elif key in {"nllb_legacy"}:
            value = parse_bool(value, default=getattr(profile, key))
        setattr(profile, key, value)

    profile.save()
    return profile


def format_duration(seconds: float | None) -> str:
    if seconds is None:
        return "--"
    td = timedelta(seconds=int(seconds))
    total = int(td.total_seconds())
    hh = total // 3600
    mm = (total % 3600) // 60
    ss = total % 60
    return f"{hh:02d}:{mm:02d}:{ss:02d}"


def serialize_profile(profile: ExecutionProfile) -> dict[str, Any]:
    return {
        "backend": profile.backend,
        "nllb_profile": profile.nllb_profile,
        "nllb_max_input_length": profile.nllb_max_input_length,
        "nllb_max_new_tokens": profile.nllb_max_new_tokens,
        "nllb_legacy": profile.nllb_legacy,
        "deepl_endpoint": profile.deepl_endpoint,
    }


def latest_run_for_asset(asset: VideoAsset, run_mode: str | None = None) -> PipelineRun | None:
    qs = asset.runs.order_by("-created_at")
    if run_mode:
        qs = qs.filter(run_mode=run_mode)
    return qs.first()


def _safe_log_tail(log_file_path: str | None) -> str:
    if not log_file_path:
        return ""

    try:
        path = Path(log_file_path)
        if not path.exists() or (not path.is_file()):
            return ""

        with path.open("r", encoding="utf-8", errors="replace") as fh:
            lines = fh.readlines()

        for line in reversed(lines):
            tail = line.strip()
            if tail:
                return tail
    except Exception:
        return ""

    return ""


def serialize_asset(asset: VideoAsset, include_log_tail: bool = False) -> dict[str, Any]:
    profile = ensure_execution_profile(asset)
    latest_run = latest_run_for_asset(asset, run_mode=RUN_MODE_PIPELINE)

    steps = []
    if latest_run:
        steps = [
            {
                "step_name": s.step_name,
                "status": s.status,
                "detail": s.detail,
                "updated_at": s.updated_at.isoformat(),
            }
            for s in latest_run.steps.order_by("id")
        ]

    latest_log_tail = _safe_log_tail(latest_run.log_file_path) if latest_run and include_log_tail else ""

    return {
        "id": asset.id,
        "file_path": asset.file_path,
        "file_name": asset.file_name,
        "source_url": asset.source_url,
        "duration_seconds": asset.duration_seconds,
        "source_duration_seconds": asset.source_duration_seconds,
        "duration_hms": format_duration(asset.duration_seconds),
        "original_language": asset.original_language,
        "is_present": asset.is_present,
        "last_seen_at": asset.last_seen_at.isoformat() if asset.last_seen_at else None,
        "profile": serialize_profile(profile),
        "latest_run": {
            "id": latest_run.id,
            "run_mode": latest_run.run_mode,
            "status": latest_run.status,
            "started_at": latest_run.started_at.isoformat() if latest_run.started_at else None,
            "finished_at": latest_run.finished_at.isoformat() if latest_run.finished_at else None,
            "exit_code": latest_run.exit_code,
            "error_message": latest_run.error_message,
            "log_file_path": latest_run.log_file_path,
            "log_url": f"/api/runs/{latest_run.id}/log",
            "log_tail": latest_log_tail,
            "steps": steps,
        }
        if latest_run
        else None,
    }


def list_assets(
    present_only: bool = True,
    include_active_runs: bool = False,
    include_log_tail: bool = False,
) -> list[dict[str, Any]]:
    qs = VideoAsset.objects.all().order_by("file_name")
    if present_only:
        if include_active_runs:
            active_asset_ids = PipelineRun.objects.filter(
                status__in=["queued", "running", "stopping"]
            ).values_list("video_asset_id", flat=True)
            qs = qs.filter(Q(is_present=True) | Q(id__in=active_asset_ids))
        else:
            qs = qs.filter(is_present=True)

    items = []
    for asset in qs:
        items.append(serialize_asset(asset, include_log_tail=include_log_tail))
    return items
