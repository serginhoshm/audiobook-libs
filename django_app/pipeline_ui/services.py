import configparser
import re
import subprocess
from datetime import timedelta
from pathlib import Path
from typing import Any

from django.conf import settings
from django.db.models import Q
from django.utils import timezone

from .models import ExecutionProfile, PipelineRun, PipelineStepStatus, VideoAsset


VIDEO_EXTENSIONS = {".mp4", ".mkv"}


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
            r"\b(el|la|los|las|de|que|por|para|con|una|uno|como|pero|est[aá]|est[aá]n|hoy)\b|[¿¡ñáéíóúü]",
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


def ensure_execution_profile(asset: VideoAsset) -> ExecutionProfile:
    profile, _ = ExecutionProfile.objects.get_or_create(video_asset=asset)
    return profile


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
        asset, created = VideoAsset.objects.update_or_create(file_path=str(path), defaults=defaults)
        ensure_execution_profile(asset)
        if created:
            discovered += 1
        else:
            updated += 1

    missing = 0
    for asset in VideoAsset.objects.filter(is_present=True):
        if asset.file_path not in present_paths:
            asset.is_present = False
            asset.last_seen_at = now
            asset.save(update_fields=["is_present", "last_seen_at"])
            missing += 1

    return {"discovered": discovered, "updated": updated, "missing": missing}


def active_run_exists(video_asset_id: int) -> bool:
    return PipelineRun.objects.filter(video_asset_id=video_asset_id, status__in=["queued", "running", "stopping"]).exists()


def queue_runs(video_ids: list[int]) -> dict[str, Any]:
    queued_ids = []
    skipped = 0

    for video_id in video_ids:
        if active_run_exists(video_id):
            skipped += 1
            continue
        run = PipelineRun.objects.create(video_asset_id=video_id, status="queued")
        for step_name in ["extract", "transcribe", "translate", "audiobook"]:
            PipelineStepStatus.objects.create(pipeline_run=run, step_name=step_name, status="pending")
        queued_ids.append(run.id)

    return {"queued": len(queued_ids), "skipped": skipped, "run_ids": queued_ids}


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
        "nllb_gpu",
        "nllb_legacy",
        "deepl_endpoint",
        "reset_deepl_keys_state",
        "cuda_enabled",
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
        elif key in {"nllb_gpu", "nllb_legacy", "reset_deepl_keys_state", "cuda_enabled"}:
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
        "nllb_gpu": profile.nllb_gpu,
        "nllb_legacy": profile.nllb_legacy,
        "deepl_endpoint": profile.deepl_endpoint,
        "reset_deepl_keys_state": profile.reset_deepl_keys_state,
        "cuda_enabled": profile.cuda_enabled,
    }


def latest_run_for_asset(asset: VideoAsset) -> PipelineRun | None:
    return asset.runs.order_by("-created_at").first()


def serialize_asset(asset: VideoAsset) -> dict[str, Any]:
    profile = ensure_execution_profile(asset)
    latest_run = latest_run_for_asset(asset)

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

    return {
        "id": asset.id,
        "file_path": asset.file_path,
        "file_name": asset.file_name,
        "duration_seconds": asset.duration_seconds,
        "duration_hms": format_duration(asset.duration_seconds),
        "original_language": asset.original_language,
        "is_present": asset.is_present,
        "last_seen_at": asset.last_seen_at.isoformat() if asset.last_seen_at else None,
        "profile": serialize_profile(profile),
        "latest_run": {
            "id": latest_run.id,
            "status": latest_run.status,
            "started_at": latest_run.started_at.isoformat() if latest_run.started_at else None,
            "finished_at": latest_run.finished_at.isoformat() if latest_run.finished_at else None,
            "exit_code": latest_run.exit_code,
            "error_message": latest_run.error_message,
            "log_file_path": latest_run.log_file_path,
            "steps": steps,
        }
        if latest_run
        else None,
    }


def list_assets(present_only: bool = True, include_active_runs: bool = False) -> list[dict[str, Any]]:
    qs = VideoAsset.objects.all().order_by("file_name")
    if present_only:
        if include_active_runs:
            active_asset_ids = PipelineRun.objects.filter(
                status__in=["queued", "running", "stopping"]
            ).values_list("video_asset_id", flat=True)
            qs = qs.filter(Q(is_present=True) | Q(id__in=active_asset_ids))
        else:
            qs = qs.filter(is_present=True)
    return [serialize_asset(asset) for asset in qs]
