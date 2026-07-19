import configparser
import json
import logging
import os
import re
import subprocess
import sys
import time
import shutil
import unicodedata
from urllib import error as urlerror
from urllib.parse import parse_qs, urlparse
from urllib import request as urlrequest
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any
from tempfile import NamedTemporaryFile

from django.conf import settings
from django.db import OperationalError
from django.db.models import Case, IntegerField, Q, Value, When
from django.utils import timezone

from .models import ExecutionProfile, PipelineRun, PipelineStepStatus, VideoAsset


logger = logging.getLogger(__name__)

try:
    from deep_translator import GoogleTranslator
except Exception:  # pragma: no cover - optional dependency fallback
    GoogleTranslator = None

try:
    from googleapiclient.discovery import build as google_api_build
except Exception:  # pragma: no cover - optional dependency fallback
    google_api_build = None


VIDEO_EXTENSIONS = {".mp4"}
PIPELINE_STEP_ORDER = ["download", "extract", "transcribe", "translate", "audiobook", "remux"]
RUN_MODE_PIPELINE = "pipeline"
STORAGE_LOCATION_EXEC = "exec"
STORAGE_LOCATION_LIBRARY = "library"
DOWNLOAD_DURATION_TOLERANCE_SECONDS = 2.5
DOWNLOAD_FORMAT_FILTER = "bv*[height>=480][height<=720]+ba/b[height>=480][height<=720]"
MAX_FILESYSTEM_NAME_BYTES = 255
THUMBNAIL_MAX_BYTES = 10 * 1024 * 1024
YTDLP_METADATA_TIMEOUT_SECONDS = 25
_YT_DLP_HELP_CACHE: str | None = None
_YOUTUBE_API_SERVICE = None
WORKER_SCOPE_GENERAL = "general"
WORKER_STEP_SCOPES = tuple(PIPELINE_STEP_ORDER)
_LEGACY_WORKDIR_WARNED = False
PLEX_POSTER_SUFFIX = "-poster.jpg"


def worker_max_slots_per_scope() -> int:
    configured = int(settings.WEBAPP.get("WORKER_MAX_SLOTS_PER_SCOPE", 1))
    return max(1, configured)


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


def _worker_role_specs() -> list[tuple[str, int]]:
    max_slots = worker_max_slots_per_scope()
    return [(scope, slot) for scope in WORKER_STEP_SCOPES for slot in range(1, max_slots + 1)]


def _worker_file_name(kind: str, scope: str, slot: int) -> str:
    if scope == WORKER_SCOPE_GENERAL and slot == 1:
        return f"worker.{kind}"
    return f"worker-{scope}-{slot}.{kind}"


def _discover_worker_processes() -> list[dict[str, Any]]:
    root = project_root()
    script_hint = str(root / "django_app" / "manage.py")
    try:
        output = subprocess.check_output(
            ["pgrep", "-fa", f"{script_hint} run_worker"],
            text=True,
            stderr=subprocess.DEVNULL,
        )
        processes: list[dict[str, Any]] = []
        seen_pids: set[int] = set()
        for line in output.splitlines():
            raw = line.strip()
            if not raw:
                continue
            pid_text, _, command = raw.partition(" ")
            if not pid_text.isdigit():
                continue

            # Keep only true run_worker command lines (exclude coordinator/collector).
            if not re.search(r"(?:^|\s)run_worker(?:\s|$)", command):
                continue

            pid = int(pid_text)
            if pid in seen_pids:
                continue

            scope_pattern = "|".join(re.escape(scope) for scope in [WORKER_SCOPE_GENERAL, *WORKER_STEP_SCOPES])
            scope_match = re.search(rf"(?:^|\s)--scope(?:=|\s+)({scope_pattern})(?:\s|$)", command)
            slot_match = re.search(r"(?:^|\s)--slot(?:=|\s+)(\d+)(?:\s|$)", command)
            scope = scope_match.group(1) if scope_match else WORKER_SCOPE_GENERAL
            slot = int(slot_match.group(1)) if slot_match else 1

            processes.append({
                "pid": pid,
                "scope": scope,
                "slot": slot,
                "command": command,
            })
            seen_pids.add(pid)

        return sorted(processes, key=lambda proc: (proc["scope"], proc["slot"], proc["pid"]))
    except Exception:
        return []


def _discover_worker_pids() -> list[int]:
    return [proc["pid"] for proc in _discover_worker_processes()]


def _worker_run_dir() -> Path:
    return project_root() / ".run" / "webapp"


def _coordinator_pid_file() -> Path:
    return _worker_run_dir() / "coordinator.pid"


def _worker_status_snapshot_file() -> Path:
    return _worker_run_dir() / "worker-status.json"


def _pid_is_running(pid: int | None) -> bool:
    if not pid:
        return False
    try:
        os.kill(pid, 0)
        return True
    except Exception:
        return False


def _pid_from_file(path: Path) -> int | None:
    if not path.exists():
        return None
    try:
        value = path.read_text(encoding="utf-8").strip()
    except Exception:
        return None
    if not value.isdigit():
        return None
    return int(value)


def _discover_coordinator_process() -> dict[str, Any] | None:
    pid_file = _coordinator_pid_file()
    pid = _pid_from_file(pid_file)
    if _pid_is_running(pid):
        return {
            "pid": pid,
            "source": "pid_file",
            "command": "run_worker_coordinator",
        }

    root = project_root()
    script_hint = str(root / "django_app" / "manage.py")
    try:
        output = subprocess.check_output(
            ["pgrep", "-fa", f"{script_hint} run_worker_coordinator"],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        return None

    for line in output.splitlines():
        raw = line.strip()
        if not raw:
            continue
        pid_text, _, command = raw.partition(" ")
        if not pid_text.isdigit():
            continue
        return {
            "pid": int(pid_text),
            "source": "process_scan",
            "command": command,
        }

    return None


def _worker_pid_file(scope: str = WORKER_SCOPE_GENERAL, slot: int = 1) -> Path:
    return _worker_run_dir() / _worker_file_name("pid", scope, slot)


def _discovery_status_file() -> Path:
    return _worker_run_dir() / "discovery-status.json"


def _worker_log_file(scope: str = WORKER_SCOPE_GENERAL, slot: int = 1) -> Path:
    return load_log_dir() / _worker_file_name("log", scope, slot)


def _worker_python_executable() -> str:
    root = project_root()
    venv_python = root / ".venv" / "bin" / "python"
    if venv_python.exists():
        return str(venv_python)
    return sys.executable


def _spawn_worker_process(scope: str, slot: int) -> int:
    run_dir = _worker_run_dir()
    run_dir.mkdir(parents=True, exist_ok=True)

    log_file = _worker_log_file(scope, slot)
    log_file.parent.mkdir(parents=True, exist_ok=True)

    root = project_root()
    command = [
        _worker_python_executable(),
        str(root / "django_app" / "manage.py"),
        "run_worker",
        "--scope",
        scope,
        "--slot",
        str(slot),
    ]

    with open(log_file, "a", encoding="utf-8") as out:
        out.write(f"[webapp] auto-starting worker process scope={scope} slot={slot}\n")

    log_handle = open(log_file, "a", encoding="utf-8")
    proc = subprocess.Popen(
        command,
        cwd=str(root),
        stdout=log_handle,
        stderr=log_handle,
        start_new_session=True,
    )
    log_handle.close()

    _worker_pid_file(scope, slot).write_text(f"{proc.pid}\n", encoding="utf-8")
    return proc.pid


def ensure_worker_running() -> dict[str, Any]:
    discovered = _discover_worker_processes()
    active_slots = {(proc["scope"], proc["slot"]) for proc in discovered}
    started_pids: list[int] = []

    for scope, slot in _worker_role_specs():
        if (scope, slot) in active_slots:
            continue
        started_pids.append(_spawn_worker_process(scope, slot))

    worker_pids = sorted({proc["pid"] for proc in discovered} | set(started_pids))
    if not started_pids:
        primary_pid = worker_pids[0] if worker_pids else None
        return {
            "started": False,
            "pid": primary_pid,
            "reason": "already_running",
            "worker_pids": worker_pids,
        }

    primary_pid = started_pids[0]
    return {
        "started": True,
        "pid": primary_pid,
        "reason": "auto_started_missing_workers",
        "worker_pids": worker_pids,
        "started_worker_pids": started_pids,
    }


def project_root() -> Path:
    return Path(settings.WEBAPP["ROOT_DIR"])


def pipeline_config_path() -> Path:
    return Path(settings.WEBAPP["PIPELINE_CONFIG"])


def load_data_root() -> Path:
    global _LEGACY_WORKDIR_WARNED

    cfg = configparser.ConfigParser(interpolation=None)
    cfg.read(pipeline_config_path(), encoding="utf-8")

    raw = cfg.get("paths", "workdir", fallback="").strip()
    if not raw:
        raw = cfg.get("paths", "data_root_relative", fallback="data").strip()
        if not _LEGACY_WORKDIR_WARNED:
            logger.warning("[config] [paths] data_root_relative is deprecated; use [paths] workdir")
            _LEGACY_WORKDIR_WARNED = True
    if raw.startswith("/"):
        return Path(raw)
    return project_root() / raw


def load_work_exec_dir() -> Path:
    return load_data_root() / "exec"


def load_library_dir() -> Path:
    path = load_data_root() / "library"
    path.mkdir(parents=True, exist_ok=True)
    return path


def load_work_temp_dir() -> Path:
    path = load_data_root() / "temp"
    path.mkdir(parents=True, exist_ok=True)
    return path


def load_work_remux_dir() -> Path:
    path = load_data_root() / "remux"
    path.mkdir(parents=True, exist_ok=True)
    return path


def canonical_asset_file_name(asset: VideoAsset) -> str:
    name = str(asset.file_name or "").strip()
    if name:
        return Path(name).name

    legacy_path = str(asset.file_path or "").strip()
    if legacy_path:
        return Path(legacy_path).name
    return ""


def _asset_storage_location(asset: VideoAsset) -> str:
    location = str(asset.storage_location or STORAGE_LOCATION_EXEC).strip().lower()
    if location not in {STORAGE_LOCATION_EXEC, STORAGE_LOCATION_LIBRARY}:
        return STORAGE_LOCATION_EXEC
    return location


def _asset_storage_dir(asset: VideoAsset) -> Path:
    return load_library_dir() if _asset_storage_location(asset) == STORAGE_LOCATION_LIBRARY else load_work_exec_dir()


def resolve_asset_video_path(asset: VideoAsset) -> Path:
    return _asset_storage_dir(asset) / canonical_asset_file_name(asset)


def normalize_asset_storage_fields(asset: VideoAsset) -> bool:
    canonical_name = canonical_asset_file_name(asset)
    if not canonical_name:
        return False

    update_fields: list[str] = []
    if asset.file_name != canonical_name:
        asset.file_name = canonical_name
        update_fields.append("file_name")

    # Keep file_path column as canonical filename only when it does not violate
    # the historical unique constraint in legacy datasets.
    conflict_exists = VideoAsset.objects.filter(file_path=canonical_name).exclude(id=asset.id).exists()
    if (not conflict_exists) and asset.file_path != canonical_name:
        asset.file_path = canonical_name
        update_fields.append("file_path")

    normalized_location = _asset_storage_location(asset)
    if asset.storage_location != normalized_location:
        asset.storage_location = normalized_location
        update_fields.append("storage_location")

    if update_fields:
        _with_sqlite_lock_retry(asset.save, update_fields=update_fields)
        return True
    return False


def is_generated_remux_sibling(video_path: Path) -> bool:
    """Return True when file follows generated remux naming '<base> (remux).mp4'."""
    if video_path.suffix.lower() not in VIDEO_EXTENSIONS:
        return False

    stem = video_path.stem
    match = re.match(r"^(?P<base>.+?)\s*\(remux\)$", stem, flags=re.IGNORECASE)
    if not match:
        return False

    base_stem = (match.group("base") or "").rstrip()
    return bool(base_stem)


def _md_value(value: Any) -> str:
    if value is None:
        return ""
    if hasattr(value, "isoformat"):
        try:
            return value.isoformat()
        except Exception:
            return str(value)
    return str(value)


def _append_markdown_table(lines: list[str], rows: list[tuple[str, Any]]) -> None:
    lines.append("| campo | valor |")
    lines.append("|---|---|")
    for key, value in rows:
        key_text = str(key).replace("\n", " ").replace("|", "\\|")
        value_text = _md_value(value).replace("\n", "<br>").replace("|", "\\|")
        lines.append(f"| {key_text} | {value_text} |")
    lines.append("")


def export_scan_index_markdown(work_exec: Path) -> None:
    assets = list(VideoAsset.objects.all().order_by("id"))
    profiles_by_asset_id = {
        profile.video_asset_id: profile
        for profile in ExecutionProfile.objects.all().order_by("video_asset_id")
    }
    runs_by_asset_id: dict[int, list[PipelineRun]] = {}
    run_ids: list[int] = []
    for run in PipelineRun.objects.select_related("video_asset").order_by("video_asset_id", "id"):
        runs_by_asset_id.setdefault(run.video_asset_id, []).append(run)
        run_ids.append(run.id)

    steps_by_run_id: dict[int, list[PipelineStepStatus]] = {}
    if run_ids:
        for step in PipelineStepStatus.objects.filter(pipeline_run_id__in=run_ids).order_by("pipeline_run_id", "id"):
            steps_by_run_id.setdefault(step.pipeline_run_id, []).append(step)

    lines: list[str] = []
    generated_at = timezone.now().isoformat()
    lines.append("# Index do Banco")
    lines.append("")
    lines.append(f"Gerado em: {generated_at}")
    lines.append("")
    lines.append(f"Total de itens: {len(assets)}")
    lines.append("")

    if not assets:
        lines.append("Nenhum item encontrado no banco.")
        lines.append("")

    for asset in assets:
        lines.append(f"## Item {asset.id}: {asset.file_name}")
        lines.append("")
        _append_markdown_table(
            lines,
            [
                ("id", asset.id),
                ("file_path", asset.file_path),
                ("file_name", asset.file_name),
                ("source_url", asset.source_url),
                ("youtube_title_original", asset.youtube_title_original),
                ("youtube_title_pt_br", asset.youtube_title_pt_br),
                ("thumbnail_path", asset.thumbnail_path),
                ("extension", asset.extension),
                ("size_bytes", asset.size_bytes),
                ("duration_seconds", asset.duration_seconds),
                ("source_duration_seconds", asset.source_duration_seconds),
                ("original_language", asset.original_language),
                ("discovered_at", asset.discovered_at),
                ("last_seen_at", asset.last_seen_at),
                ("is_present", asset.is_present),
                ("is_deleted", asset.is_deleted),
            ],
        )

        profile = profiles_by_asset_id.get(asset.id)
        lines.append("### ExecutionProfile")
        lines.append("")
        if profile is None:
            lines.append("Sem execution_profile.")
            lines.append("")
        else:
            _append_markdown_table(
                lines,
                [
                    ("id", profile.id),
                    ("video_asset_id", profile.video_asset_id),
                    ("updated_at", profile.updated_at),
                ],
            )

        runs = runs_by_asset_id.get(asset.id, [])
        lines.append(f"### Runs ({len(runs)})")
        lines.append("")
        if not runs:
            lines.append("Sem runs.")
            lines.append("")
            continue

        for run in runs:
            lines.append(f"#### Run {run.id}")
            lines.append("")
            _append_markdown_table(
                lines,
                [
                    ("id", run.id),
                    ("video_asset_id", run.video_asset_id),
                    ("run_mode", run.run_mode),
                    ("status", run.status),
                    ("started_at", run.started_at),
                    ("finished_at", run.finished_at),
                    ("exit_code", run.exit_code),
                    ("error_message", run.error_message),
                    ("log_file_path", run.log_file_path),
                    ("pid", run.pid),
                    ("process_group_id", run.process_group_id),
                    ("stop_requested", run.stop_requested),
                    ("created_at", run.created_at),
                    ("updated_at", run.updated_at),
                ],
            )

            steps = steps_by_run_id.get(run.id, [])
            lines.append(f"##### Steps ({len(steps)})")
            lines.append("")
            if not steps:
                lines.append("Sem steps.")
                lines.append("")
                continue

            for step in steps:
                lines.append(f"- Step {step.id}: {step.step_name} | status={step.status}")
                lines.append(f"  - detail: {_md_value(step.detail)}")
                lines.append(f"  - updated_at: {_md_value(step.updated_at)}")
            lines.append("")

    index_path = work_exec / "index.md"
    index_path.write_text("\n".join(lines), encoding="utf-8")


def load_download_dir() -> Path:
    return load_work_exec_dir()


def _legacy_thumbnail_dir() -> Path:
    return project_root() / "video-thumbs"


def _migrate_legacy_thumbnail_dir(target_dir: Path) -> None:
    legacy_dir = _legacy_thumbnail_dir()
    if not legacy_dir.exists() or not legacy_dir.is_dir():
        return

    if legacy_dir == target_dir:
        return

    for candidate in legacy_dir.iterdir():
        if not candidate.is_file():
            continue
        destination = target_dir / candidate.name
        if destination.exists():
            continue
        try:
            shutil.move(str(candidate), str(destination))
        except Exception:
            continue

    try:
        if not any(legacy_dir.iterdir()):
            legacy_dir.rmdir()
    except Exception:
        pass


def _remap_legacy_thumbnail_path(current_path: str) -> str:
    raw = str(current_path or "").strip()
    if not raw:
        return ""

    legacy_dir = _legacy_thumbnail_dir()
    candidate = Path(raw)
    try:
        relative = candidate.relative_to(legacy_dir)
    except Exception:
        return raw

    migrated_path = load_thumbnail_dir() / relative
    if migrated_path.exists():
        return str(migrated_path)
    return raw


def load_thumbnail_dir() -> Path:
    path = load_data_root() / "thumbs"
    path.mkdir(parents=True, exist_ok=True)
    _migrate_legacy_thumbnail_dir(path)
    return path


def load_log_dir() -> Path:
    path = load_data_root() / "logs"
    path.mkdir(parents=True, exist_ok=True)
    return path


def canonical_run_log_name(log_file_path: str | None) -> str:
    raw = str(log_file_path or "").strip()
    if not raw:
        return ""
    return Path(raw).name


def resolve_run_log_path(log_file_path: str | None) -> Path | None:
    raw = str(log_file_path or "").strip()
    if not raw:
        return None

    candidate = Path(raw)
    if candidate.is_absolute() and candidate.exists() and candidate.is_file():
        return candidate

    normalized_name = candidate.name
    if not normalized_name:
        return None
    return load_log_dir() / normalized_name


def normalize_run_log_storage(run: PipelineRun) -> bool:
    canonical = canonical_run_log_name(run.log_file_path)
    if canonical == str(run.log_file_path or ""):
        return False
    run.log_file_path = canonical
    _with_sqlite_lock_retry(run.save, update_fields=["log_file_path"])
    return True


def _next_available_destination(destination: Path) -> Path:
    if not destination.exists():
        return destination

    stem = destination.stem
    suffix = destination.suffix
    index = 1
    while True:
        if suffix:
            alternative = destination.parent / f"{stem}.migrated-{index}{suffix}"
        else:
            alternative = destination.parent / f"{stem}.migrated-{index}"
        if not alternative.exists():
            return alternative
        index += 1


def _is_related_asset_name(candidate_name: str, canonical_name: str, stem: str) -> bool:
    if candidate_name == canonical_name:
        return True
    return candidate_name.startswith(f"{stem}.") or candidate_name.startswith(f"{stem} ") or candidate_name.startswith(f"{stem}(")


def _rename_library_artifacts(asset: VideoAsset, new_base_name: str) -> str:
    canonical_name = canonical_asset_file_name(asset)
    if not canonical_name:
        return ""

    source_dir = load_library_dir()
    if not source_dir.exists():
        return canonical_name

    current_stem = Path(canonical_name).stem
    desired_stem = _truncate_filesystem_name(new_base_name)
    if not desired_stem or desired_stem == current_stem:
        return canonical_name

    renamed_video_name = canonical_name
    for candidate in sorted(source_dir.iterdir(), key=lambda path: path.name.lower()):
        if not candidate.is_file():
            continue
        if not _is_related_asset_name(candidate.name, canonical_name, current_stem):
            continue

        suffix = candidate.name[len(current_stem):]
        destination = source_dir / f"{desired_stem}{suffix}"
        destination = _next_available_destination(destination)
        shutil.move(str(candidate), str(destination))

        if candidate.name == canonical_name:
            renamed_video_name = destination.name

    return renamed_video_name


def _canonical_thumbnail_name(value: str) -> str:
    raw = str(value or "").strip()
    if not raw:
        return ""
    return Path(raw).name


def resolve_asset_thumbnail_path(asset: VideoAsset) -> Path | None:
    raw = str(asset.thumbnail_path or "").strip()
    if not raw:
        return None

    candidate = Path(raw)
    if candidate.is_absolute():
        migrated = _remap_legacy_thumbnail_path(raw)
        migrated_path = Path(migrated)
        if migrated_path.exists() and migrated_path.is_file():
            return migrated_path
        if candidate.exists() and candidate.is_file():
            return candidate

    normalized_name = _canonical_thumbnail_name(raw)
    if not normalized_name:
        return None
    return load_thumbnail_dir() / normalized_name


def normalize_asset_thumbnail_field(asset: VideoAsset) -> bool:
    canonical = _canonical_thumbnail_name(asset.thumbnail_path)
    if canonical == str(asset.thumbnail_path or ""):
        return False
    asset.thumbnail_path = canonical
    _with_sqlite_lock_retry(asset.save, update_fields=["thumbnail_path"])
    return True


def get_discovery_status() -> dict[str, Any]:
    status = {
        "in_progress": False,
        "last_completed_at": None,
    }

    path = _discovery_status_file()
    if not path.exists():
        return status

    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return status

    if isinstance(payload, dict):
        status["in_progress"] = bool(payload.get("in_progress", False))
        last_completed_at = str(payload.get("last_completed_at") or "").strip()
        status["last_completed_at"] = last_completed_at or None
    return status


def set_discovery_status(*, in_progress: bool, last_completed_at: str | None = None) -> dict[str, Any]:
    run_dir = _worker_run_dir()
    run_dir.mkdir(parents=True, exist_ok=True)

    current = get_discovery_status()
    payload = {
        "in_progress": bool(in_progress),
        "last_completed_at": last_completed_at if last_completed_at is not None else current.get("last_completed_at"),
    }
    _discovery_status_file().write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    return payload


def _youtube_thumbnail_url_from_metadata(metadata: dict[str, Any]) -> str:
    direct = str(metadata.get("thumbnail") or "").strip()
    if direct:
        return direct

    thumbs = metadata.get("thumbnails")
    if isinstance(thumbs, list):
        for item in reversed(thumbs):
            if not isinstance(item, dict):
                continue
            candidate = str(item.get("url") or "").strip()
            if candidate:
                return candidate
    return ""


def _thumbnail_extension_from_url(url: str) -> str:
    path = urlparse(url).path.lower()
    suffix = Path(path).suffix.lower()
    if suffix in {".jpg", ".jpeg", ".png", ".webp"}:
        return ".jpg" if suffix == ".jpeg" else suffix
    return ".jpg"


def _download_thumbnail_from_url(url: str, target_stem: str) -> Path | None:
    clean_url = str(url or "").strip()
    if not clean_url:
        return None

    target_dir = load_thumbnail_dir()
    target_path = target_dir / f"{target_stem}{_thumbnail_extension_from_url(clean_url)}"

    try:
        req = urlrequest.Request(clean_url, headers={"User-Agent": "Mozilla/5.0"}, method="GET")
        with urlrequest.urlopen(req, timeout=20) as resp:
            body = resp.read(THUMBNAIL_MAX_BYTES + 1)
        if (not body) or len(body) > THUMBNAIL_MAX_BYTES:
            return None
        target_path.write_bytes(body)
        return target_path
    except (urlerror.URLError, TimeoutError, OSError):
        return None
    except Exception:
        return None


def _download_best_thumbnail_for_asset(asset: VideoAsset, metadata: dict[str, Any] | None = None) -> Path | None:
    details = metadata if isinstance(metadata, dict) else {}
    stem = Path(canonical_asset_file_name(asset)).stem or f"video-{asset.id}"

    thumb_url = _youtube_thumbnail_url_from_metadata(details)
    if thumb_url:
        saved = _download_thumbnail_from_url(thumb_url, f"{stem}-{asset.id}-refresh")
        if saved is not None:
            return saved

    for fallback_url in _youtube_thumbnail_fallback_urls(asset.source_url):
        saved = _download_thumbnail_from_url(fallback_url, f"{stem}-{asset.id}-refresh")
        if saved is not None:
            return saved

    return None


def _convert_image_to_jpeg(source_path: Path, destination_path: Path) -> None:
    try:
        from PIL import Image, ImageOps
    except Exception as exc:
        raise RuntimeError(f"Pillow unavailable for JPEG conversion: {exc}") from exc

    destination_path.parent.mkdir(parents=True, exist_ok=True)

    temporary_path: Path | None = None
    try:
        with Image.open(source_path) as image:
            normalized = ImageOps.exif_transpose(image)
            if normalized.mode != "RGB":
                normalized = normalized.convert("RGB")

            with NamedTemporaryFile(
                mode="wb",
                delete=False,
                dir=str(destination_path.parent),
                suffix=".tmp",
            ) as temp_file:
                temporary_path = Path(temp_file.name)

            normalized.save(temporary_path, format="JPEG", quality=92)

        temporary_path.replace(destination_path)
    finally:
        if temporary_path is not None and temporary_path.exists():
            try:
                temporary_path.unlink()
            except Exception:
                pass


def _refresh_plex_posters_for_library_asset(
    asset: VideoAsset,
    metadata: dict[str, Any] | None = None,
) -> dict[str, Any]:
    if _asset_storage_location(asset) != STORAGE_LOCATION_LIBRARY:
        return {
            "status": "skipped",
            "detail": "asset is not in library",
            "files": [],
        }

    source_image = _download_best_thumbnail_for_asset(asset, metadata=metadata)
    if source_image is None:
        return {
            "status": "failed",
            "detail": "thumbnail unavailable for Plex poster generation",
            "files": [],
        }

    video_name = canonical_asset_file_name(asset)
    video_stem = Path(video_name).stem if video_name else ""
    if not video_stem:
        return {
            "status": "failed",
            "detail": "unable to resolve video file name for Plex poster generation",
            "files": [],
        }

    library_dir = load_library_dir()
    stem_poster = library_dir / f"{video_stem}.jpg"
    plex_poster = library_dir / f"{video_stem}{PLEX_POSTER_SUFFIX}"

    _convert_image_to_jpeg(source_image, stem_poster)
    _convert_image_to_jpeg(source_image, plex_poster)

    return {
        "status": "updated",
        "detail": "generated stem poster and stem-poster.jpg",
        "files": [stem_poster.name, plex_poster.name],
    }


def _youtube_video_id_from_url(source_url: Any) -> str:
    raw = str(source_url or "").strip()
    if not raw:
        return ""

    try:
        parsed = urlparse(raw)
    except Exception:
        return ""

    host = parsed.netloc.lower()
    path_parts = [part for part in parsed.path.split("/") if part]
    candidate = ""

    if "youtu.be" in host:
        candidate = path_parts[0] if path_parts else ""
    elif "youtube.com" in host:
        query = parse_qs(parsed.query)
        candidate = (query.get("v") or [""])[0]
        if not candidate and len(path_parts) >= 2 and path_parts[0] in {"shorts", "embed", "v"}:
            candidate = path_parts[1]

    candidate = str(candidate or "").strip()
    if re.fullmatch(r"[A-Za-z0-9_-]{11}", candidate):
        return candidate
    return ""


def _youtube_thumbnail_fallback_urls(source_url: Any) -> list[str]:
    video_id = _youtube_video_id_from_url(source_url)
    if not video_id:
        return []

    # Order from best to safest so we keep quality when available.
    return [
        f"https://i.ytimg.com/vi_webp/{video_id}/maxresdefault.webp",
        f"https://i.ytimg.com/vi/{video_id}/maxresdefault.jpg",
        f"https://i.ytimg.com/vi/{video_id}/hqdefault.jpg",
        f"https://i.ytimg.com/vi/{video_id}/mqdefault.jpg",
        f"https://i.ytimg.com/vi/{video_id}/default.jpg",
    ]


def ensure_asset_thumbnail(asset: VideoAsset, metadata: dict[str, Any] | None = None) -> str:
    current = str(asset.thumbnail_path or "").strip()
    if current:
        resolved = resolve_asset_thumbnail_path(asset)
        if resolved is not None and resolved.exists() and resolved.is_file():
            canonical_name = resolved.name
            if asset.thumbnail_path != canonical_name:
                asset.thumbnail_path = canonical_name
                _with_sqlite_lock_retry(asset.save, update_fields=["thumbnail_path"])
            return canonical_name

    if not _is_youtube_source(asset.source_url):
        return ""

    details = metadata
    if details is None:
        try:
            details = _probe_youtube_metadata(asset.source_url)
        except Exception:
            details = {}

    thumb_url = _youtube_thumbnail_url_from_metadata(details if isinstance(details, dict) else {})
    stem = Path(asset.file_name).stem or f"video-{asset.id}"

    if thumb_url:
        saved_path = _download_thumbnail_from_url(thumb_url, f"{stem}-{asset.id}")
        if saved_path is not None:
            return saved_path.name

    # Fallback when metadata probe is flaky/rate-limited: derive thumbnail directly from video id.
    for fallback_url in _youtube_thumbnail_fallback_urls(asset.source_url):
        saved_path = _download_thumbnail_from_url(fallback_url, f"{stem}-{asset.id}")
        if saved_path is not None:
            return saved_path.name

    return ""


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


def _normalize_title_text(text: Any) -> str:
    normalized = unicodedata.normalize("NFKC", str(text or ""))
    normalized = re.sub(r"\s+", " ", normalized).strip()
    return normalized


def _truncate_filesystem_name(text: Any, max_bytes: int = MAX_FILESYSTEM_NAME_BYTES) -> str:
    normalized = _normalize_title_text(text)
    if not normalized:
        return ""

    encoded = normalized.encode("utf-8")
    if len(encoded) <= max_bytes:
        return normalized

    truncated = encoded[:max_bytes]
    while truncated:
        try:
            return truncated.decode("utf-8").rstrip(" .")
        except UnicodeDecodeError:
            truncated = truncated[:-1]
    return ""


def _normalize_translation_source(language: Any) -> str:
    source = _normalize_title_text(language).lower()
    if not source:
        return "auto"
    if source.startswith("pt"):
        return "auto"
    if re.fullmatch(r"[a-z]{2,3}(?:-[a-z0-9]+)*", source):
        return source
    return "auto"


def _is_youtube_source(source_url: Any) -> bool:
    raw = str(source_url or "").strip()
    if not raw:
        return False

    try:
        host = urlparse(raw).netloc.lower()
    except Exception:
        return False
    return "youtube.com" in host or "youtu.be" in host


def _youtube_api_service():
    global _YOUTUBE_API_SERVICE

    if _YOUTUBE_API_SERVICE is not None:
        return _YOUTUBE_API_SERVICE
    if google_api_build is None:
        raise RuntimeError("google-api-python-client is not installed")

    api_key = str(getattr(settings, "WEBAPP", {}).get("YOUTUBE_DATA_API_KEY", "")).strip()
    if not api_key:
        raise RuntimeError("YOUTUBE_DATA_API_KEY is not configured in config/pipeline.ini")

    # Keep this as a lightweight read-only client; the pipeline still uses yt-dlp.
    _YOUTUBE_API_SERVICE = google_api_build("youtube", "v3", developerKey=api_key, cache_discovery=False)
    return _YOUTUBE_API_SERVICE


def _youtube_metadata_from_api(video_id: str) -> dict[str, Any]:
    service = _youtube_api_service()
    response = service.videos().list(
        part="snippet",
        id=video_id,
        fields=(
            "items(id,snippet(title,channelTitle,publishedAt,defaultAudioLanguage,defaultLanguage,tags,localized,"
            "thumbnails(default(url),medium(url),high(url),standard(url),maxres(url))))"
        ),
    ).execute()

    items = response.get("items") or []
    if not items:
        return {}

    item = items[0] if isinstance(items, list) else {}
    snippet = item.get("snippet") if isinstance(item, dict) else {}
    if not isinstance(snippet, dict):
        return {}

    thumbnails_payload = snippet.get("thumbnails")
    thumbnails: list[dict[str, Any]] = []
    if isinstance(thumbnails_payload, dict):
        quality_order = ["default", "medium", "high", "standard", "maxres"]
        for quality in quality_order:
            candidate = thumbnails_payload.get(quality)
            if not isinstance(candidate, dict):
                continue
            url = str(candidate.get("url") or "").strip()
            if not url:
                continue
            thumbnails.append({"url": url, "quality": quality})

    return {
        "id": str(item.get("id") or video_id),
        "title": str(snippet.get("title") or "").strip(),
        "channelTitle": str(snippet.get("channelTitle") or "").strip(),
        "publishedAt": str(snippet.get("publishedAt") or "").strip(),
        "language": str(
            snippet.get("defaultAudioLanguage")
            or snippet.get("defaultLanguage")
            or ""
        ).strip(),
        "tags": snippet.get("tags") if isinstance(snippet.get("tags"), list) else [],
        "thumbnail": thumbnails[-1]["url"] if thumbnails else "",
        "thumbnails": thumbnails,
    }


def _translate_title_pt_br(title: str, source_language: Any = None) -> str:
    normalized = _normalize_title_text(title)
    if not normalized:
        return ""
    if GoogleTranslator is None:
        return normalized

    try:
        translated = GoogleTranslator(
            source=_normalize_translation_source(source_language),
            target="pt",
        ).translate(normalized)
    except Exception:
        translated = normalized
    return _normalize_title_text(translated)


def _title_fields_for_asset(asset: VideoAsset, file_name: str) -> dict[str, str]:
    current_original = _normalize_title_text(asset.youtube_title_original)
    current_pt_br = _normalize_title_text(asset.youtube_title_pt_br)
    if current_original and current_pt_br:
        return {}

    fallback_title = _truncate_filesystem_name(file_name)
    updates: dict[str, str] = {}

    if _is_youtube_source(asset.source_url):
        title_original = current_original
        if not title_original:
            try:
                metadata = _probe_youtube_metadata(asset.source_url)
            except Exception:
                metadata = {}
            title_original = _truncate_filesystem_name(metadata.get("title")) or fallback_title
            updates["youtube_title_original"] = title_original

        if not current_pt_br:
            updates["youtube_title_pt_br"] = _translate_title_pt_br(title_original, asset.original_language) or title_original
        return updates

    if not current_original:
        updates["youtube_title_original"] = fallback_title
    if not current_pt_br:
        updates["youtube_title_pt_br"] = current_original or fallback_title
    return updates


def _download_date_prefix(now=None) -> str:
    current = now or timezone.now()
    return current.strftime("%Y-%m-%d")


def _yt_dlp_supports_option(option: str) -> bool:
    global _YT_DLP_HELP_CACHE

    if _YT_DLP_HELP_CACHE is None:
        try:
            _YT_DLP_HELP_CACHE = subprocess.check_output(
                ["yt-dlp", "--help"], stderr=subprocess.STDOUT, text=True
            )
        except Exception:
            _YT_DLP_HELP_CACHE = ""

    return option in _YT_DLP_HELP_CACHE


def _yt_dlp_js_runtime_args() -> list[str]:
    if not _yt_dlp_supports_option("--js-runtimes"):
        return []

    runtimes: list[str] = []
    for runtime in ("node", "deno"):
        runtime_path = shutil.which(runtime)
        if runtime_path:
            runtimes.append(f"{runtime}:{runtime_path}")

    if runtimes:
        return ["--js-runtimes", ",".join(runtimes)]
    return []


def _yt_dlp_extractor_args() -> list[str]:
    if not _yt_dlp_supports_option("--extractor-args"):
        return []
    # Prefer web client first to avoid API 400 precondition failures seen on ios/android.
    return ["--extractor-args", "youtube:player_client=web"]


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
    try:
        from pytubefix import YouTube

        yt = YouTube(url)
        title = str(getattr(yt, "title", "") or "").strip()
        if title:
            return {"title": title}
    except Exception:
        pass

    base = [
        "yt-dlp",
        "--ignore-config",
        "--no-playlist",
        "--skip-download",
        "--dump-single-json",
        *_yt_dlp_js_runtime_args(),
    ]

    attempts = [
        [*base, *_yt_dlp_extractor_args(), url],
        [*base, url],
    ]

    output = ""
    last_detail = ""
    for command in attempts:
        try:
            output = subprocess.check_output(
                command,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=YTDLP_METADATA_TIMEOUT_SECONDS,
            )
            break
        except subprocess.TimeoutExpired as exc:
            last_detail = f"timeout after {YTDLP_METADATA_TIMEOUT_SECONDS}s ({exc})"
        except subprocess.CalledProcessError as exc:
            last_detail = (exc.output or "").strip() or str(exc)
    else:
        raise RuntimeError(f"yt-dlp failed to read metadata: {last_detail}")

    data: dict[str, Any] | None = None
    parse_error: json.JSONDecodeError | None = None

    # yt-dlp can emit warnings before the JSON payload even with --dump-single-json.
    candidates = [output.strip()]
    candidates.extend(line.strip() for line in reversed(output.splitlines()) if line.strip())
    for candidate in candidates:
        try:
            parsed = json.loads(candidate)
        except json.JSONDecodeError as exc:
            parse_error = exc
            continue
        if isinstance(parsed, dict):
            data = parsed
            break

    if data is None:
        preview = output.strip().splitlines()[0] if output.strip() else ""
        raise RuntimeError(
            f"yt-dlp returned non-JSON metadata output{': ' + preview if preview else ''}"
        ) from parse_error

    return data


def refresh_youtube_title_fields(video_ids: list[int] | None = None) -> dict[str, Any]:
    ids = [int(video_id) for video_id in (video_ids or []) if str(video_id).strip()]
    if not ids:
        raise ValueError("video_ids is empty")

    results = {
        "refreshed": 0,
        "skipped": 0,
        "failed": 0,
        "plex_generated": 0,
        "plex_failed": 0,
        "plex_skipped": 0,
        "items": [],
    }
    assets = VideoAsset.objects.filter(id__in=ids, is_deleted=False, storage_location=STORAGE_LOCATION_LIBRARY)

    for asset in assets:
        item_result = {
            "video_id": asset.id,
            "status": "skipped",
            "detail": "",
            "plex_poster_status": "skipped",
            "plex_poster_detail": "",
            "plex_poster_files": [],
        }
        try:
            if not _is_youtube_source(asset.source_url):
                item_result["detail"] = "source is not YouTube"
                results["skipped"] += 1
                results["items"].append(item_result)
                continue

            video_id = _youtube_video_id_from_url(asset.source_url)
            if not video_id:
                item_result["detail"] = "unable to resolve YouTube video id"
                results["skipped"] += 1
                results["items"].append(item_result)
                continue

            metadata: dict[str, Any]
            try:
                metadata = _youtube_metadata_from_api(video_id)
            except Exception as api_exc:
                item_result["status"] = "failed"
                item_result["detail"] = f"metadata unavailable: {api_exc}"
                results["failed"] += 1
                results["items"].append(item_result)
                continue

            new_original = _truncate_filesystem_name(metadata.get("title"))
            if not new_original:
                item_result["status"] = "failed"
                item_result["detail"] = "title missing from API response"
                results["failed"] += 1
                results["items"].append(item_result)
                continue

            updates: list[str] = []

            if asset.youtube_title_original != new_original:
                asset.youtube_title_original = new_original
                updates.append("youtube_title_original")

            translated = _translate_title_pt_br(new_original, metadata.get("language")) or new_original
            if asset.youtube_title_pt_br != translated:
                asset.youtube_title_pt_br = translated
                updates.append("youtube_title_pt_br")

            if _asset_storage_location(asset) == STORAGE_LOCATION_LIBRARY:
                current_name = canonical_asset_file_name(asset)
                desired_base_name = _truncate_filesystem_name(asset.youtube_title_pt_br or asset.youtube_title_original)
                renamed_name = _rename_library_artifacts(asset, desired_base_name)
                if renamed_name and renamed_name != current_name:
                    asset.file_name = renamed_name
                    if not str(asset.file_path or "").strip() or Path(str(asset.file_path or "")).name == current_name:
                        asset.file_path = renamed_name
                    updates.append("file_name")
                    if asset.file_path == renamed_name:
                        updates.append("file_path")

            try:
                plex_result = _refresh_plex_posters_for_library_asset(asset, metadata=metadata)
            except Exception as exc:
                plex_result = {
                    "status": "failed",
                    "detail": f"unexpected error while generating Plex poster: {exc}",
                    "files": [],
                }

            item_result["plex_poster_status"] = str(plex_result.get("status") or "skipped")
            item_result["plex_poster_detail"] = str(plex_result.get("detail") or "")
            item_result["plex_poster_files"] = plex_result.get("files") if isinstance(plex_result.get("files"), list) else []

            if item_result["plex_poster_status"] == "updated":
                results["plex_generated"] += 1
            elif item_result["plex_poster_status"] == "failed":
                results["plex_failed"] += 1
            else:
                results["plex_skipped"] += 1

            if updates:
                _with_sqlite_lock_retry(asset.save, update_fields=updates)
                item_result["status"] = "refreshed"
                item_result["detail"] = ", ".join(updates)
                results["refreshed"] += 1
            else:
                item_result["status"] = "unchanged"
                item_result["detail"] = "no changes"
                results["skipped"] += 1

            if item_result["plex_poster_detail"]:
                item_result["detail"] = (
                    f"{item_result['detail']}; plex: {item_result['plex_poster_status']}"
                    f" ({item_result['plex_poster_detail']})"
                )
            results["items"].append(item_result)
        except Exception as exc:
            item_result["status"] = "failed"
            item_result["detail"] = str(exc)
            results["failed"] += 1
            results["items"].append(item_result)

    return results


def update_library_asset_fields(video_id: int, payload: dict[str, Any]) -> dict[str, Any]:
    asset = VideoAsset.objects.filter(id=video_id, is_deleted=False, storage_location=STORAGE_LOCATION_LIBRARY).first()
    if asset is None:
        raise ValueError("asset not found in library")

    updates: list[str] = []

    source_url = str(payload.get("source_url") or "").strip()
    if source_url != asset.source_url:
        if source_url and not _is_youtube_source(source_url):
            raise ValueError("source_url must be a valid YouTube URL or be empty")
        asset.source_url = source_url
        updates.append("source_url")

    youtube_title_original = _normalize_title_text(payload.get("youtube_title_original"))
    if youtube_title_original != _normalize_title_text(asset.youtube_title_original):
        asset.youtube_title_original = youtube_title_original
        updates.append("youtube_title_original")

    youtube_title_pt_br = _normalize_title_text(payload.get("youtube_title_pt_br"))
    if youtube_title_pt_br != _normalize_title_text(asset.youtube_title_pt_br):
        asset.youtube_title_pt_br = youtube_title_pt_br
        updates.append("youtube_title_pt_br")

    if updates:
        _with_sqlite_lock_retry(asset.save, update_fields=updates)

    return {
        "updated": bool(updates),
        "update_fields": updates,
        "asset": serialize_asset(asset, include_log_tail=False),
    }


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
        *_yt_dlp_extractor_args(),
        "-f",
        "bv*+ba/b/best[ext=mp4]/best",
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
    youtube_title_original = _truncate_filesystem_name(metadata.get("title"))
    youtube_title_pt_br = _translate_title_pt_br(youtube_title_original, metadata.get("language"))

    asset = VideoAsset.objects.create(
        file_path=target_path.name,
        file_name=target_path.name,
        source_url=source_url,
        youtube_title_original=youtube_title_original,
        youtube_title_pt_br=youtube_title_pt_br,
        thumbnail_path="",
        extension=".mp4",
        size_bytes=0,
        duration_seconds=None,
        source_duration_seconds=float(metadata.get("duration")) if metadata.get("duration") is not None else None,
        original_language="auto",
        discovered_at=now,
        last_seen_at=now,
        is_present=False,
    )
    thumbnail_path = ensure_asset_thumbnail(asset, metadata=metadata)
    if thumbnail_path:
        asset.thumbnail_path = thumbnail_path
        asset.save(update_fields=["thumbnail_path"])
    ensure_execution_profile(asset)

    run = _create_pipeline_run(asset, status="queued")

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
    video_path = resolve_asset_video_path(asset)
    stem_path = video_path.with_suffix("")
    remux_video_path = (
        load_library_dir() / f"{video_path.stem} (remux){video_path.suffix}"
        if _asset_storage_location(asset) == STORAGE_LOCATION_LIBRARY
        else load_work_remux_dir() / f"{video_path.stem} (remux){video_path.suffix}"
    )

    def _find_remux_evidence_path() -> Path:
        source_stem = video_path.stem.lower()
        source_ext = video_path.suffix.lower()
        remux_dir = load_library_dir() if _asset_storage_location(asset) == STORAGE_LOCATION_LIBRARY else load_work_remux_dir()
        exec_dir = video_path.parent

        preferred = remux_video_path
        if preferred.exists():
            return preferred

        if remux_dir.exists():
            try:
                for candidate in remux_dir.iterdir():
                    if not candidate.is_file():
                        continue
                    name_lower = candidate.name.lower()
                    if candidate.suffix.lower() != source_ext:
                        continue
                    if source_stem in name_lower and "remux" in name_lower:
                        return candidate
            except Exception:
                pass

        if exec_dir.exists():
            try:
                for candidate in exec_dir.iterdir():
                    if not candidate.is_file():
                        continue
                    name_lower = candidate.name.lower()
                    if candidate.suffix.lower() != source_ext:
                        continue
                    if source_stem in name_lower and "remux" in name_lower:
                        return candidate
            except Exception:
                pass

        return preferred

    def _first_existing(*paths: Path) -> Path:
        for path in paths:
            if path.exists():
                return path
        return paths[0]

    return {
        "video": video_path,
        "wav": stem_path.with_suffix(".wav"),
        "mp3": stem_path.with_suffix(".mp3"),
        "srt": stem_path.with_suffix(".srt"),
        "srtpt": stem_path.with_suffix(".srtpt"),
        "pt_wav": stem_path.with_suffix(".pt.wav"),
        "remux_video": _find_remux_evidence_path(),
    }


SRT_RANGE_PATTERN = re.compile(
    r"(\d{2}):(\d{2}):(\d{2})[,.](\d{3})\s*-->\s*(\d{2}):(\d{2}):(\d{2})[,.](\d{3})"
)
VIDEO_SRT_REUSE_TOLERANCE_SECONDS = 4.0
TRANSLATION_REUSE_TOLERANCE_SECONDS = 1.5
AUDIOBOOK_REUSE_TOLERANCE_SECONDS = 4.0


def _parts_to_seconds(hours: str, minutes: str, seconds: str, millis: str) -> float:
    return (int(hours) * 3600) + (int(minutes) * 60) + int(seconds) + (int(millis) / 1000.0)


def _srt_last_end_seconds(path: Path) -> float | None:
    if not path.exists():
        return None

    last_end: float | None = None
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                match = SRT_RANGE_PATTERN.search(line)
                if not match:
                    continue
                last_end = _parts_to_seconds(match.group(5), match.group(6), match.group(7), match.group(8))
    except Exception:
        return None

    return last_end


def _can_reuse_transcript(video_path: Path, srt_path: Path) -> tuple[bool, str]:
    video_duration = ffprobe_duration_seconds(video_path)
    srt_end = _srt_last_end_seconds(srt_path)

    if video_duration is None:
        return False, "Transcript check skipped: unable to read video duration"
    if srt_end is None:
        return False, "Transcript check skipped: SRT not found or invalid"

    if srt_end + VIDEO_SRT_REUSE_TOLERANCE_SECONDS >= video_duration:
        return True, (
            "Reused existing transcript: "
            f"SRT end {srt_end:.1f}s >= video {video_duration:.1f}s - {VIDEO_SRT_REUSE_TOLERANCE_SECONDS:.1f}s"
        )

    return False, (
        "Transcript regeneration required: "
        f"SRT end {srt_end:.1f}s < video {video_duration:.1f}s - {VIDEO_SRT_REUSE_TOLERANCE_SECONDS:.1f}s"
    )


def _can_reuse_translation(srt_path: Path, srtpt_path: Path) -> tuple[bool, str]:
    source_srt_end = _srt_last_end_seconds(srt_path)
    translated_srt_end = _srt_last_end_seconds(srtpt_path)

    if source_srt_end is None:
        return False, "Translation check skipped: source SRT not found or invalid"
    if translated_srt_end is None:
        return False, "Translation check skipped: translated SRTPT not found or invalid"

    if translated_srt_end + TRANSLATION_REUSE_TOLERANCE_SECONDS >= source_srt_end:
        return True, (
            "Reused existing translation: "
            f"SRTPT end {translated_srt_end:.1f}s >= SRT {source_srt_end:.1f}s - {TRANSLATION_REUSE_TOLERANCE_SECONDS:.1f}s"
        )

    return False, (
        "Translation regeneration required: "
        f"SRTPT end {translated_srt_end:.1f}s < SRT {source_srt_end:.1f}s - {TRANSLATION_REUSE_TOLERANCE_SECONDS:.1f}s"
    )


def _can_reuse_audiobook(srt_path: Path, srtpt_path: Path, out_wav_path: Path) -> tuple[bool, str]:
    if not out_wav_path.exists():
        return False, "Audiobook check skipped: PT WAV not found"

    translation_ok, translation_detail = _can_reuse_translation(srt_path, srtpt_path)
    if not translation_ok:
        return False, (
            "Audiobook regeneration required: "
            f"translation artifact check failed ({translation_detail})"
        )

    target_seconds = _srt_last_end_seconds(srtpt_path)
    generated_seconds = ffprobe_duration_seconds(out_wav_path)

    if target_seconds is None:
        return False, "Audiobook check skipped: translated SRTPT not found or invalid"
    if generated_seconds is None:
        return False, "Audiobook check skipped: unable to read PT WAV duration"

    delta_seconds = generated_seconds - target_seconds
    if abs(delta_seconds) <= AUDIOBOOK_REUSE_TOLERANCE_SECONDS:
        return True, (
            "Reused existing audiobook: "
            f"PT WAV {generated_seconds:.1f}s vs SRTPT {target_seconds:.1f}s "
            f"(delta {delta_seconds:+.1f}s, tolerance {AUDIOBOOK_REUSE_TOLERANCE_SECONDS:.1f}s)"
        )

    return False, (
        "Audiobook regeneration required: "
        f"PT WAV {generated_seconds:.1f}s vs SRTPT {target_seconds:.1f}s "
        f"(delta {delta_seconds:+.1f}s exceeds tolerance {AUDIOBOOK_REUSE_TOLERANCE_SECONDS:.1f}s)"
    )


def _infer_translation_source_lang_for_scan(asset: VideoAsset, video_path: Path) -> str:
    persisted = (asset.original_language or "").strip()
    if persisted in {"ar", "de", "en", "es", "fr", "hi", "it", "ja", "ko", "nl", "pl", "pt", "ru", "tr", "uk", "zh-CN"}:
        return persisted

    inferred = infer_language_from_srt(video_path)
    if inferred in {"es", "zh-CN"}:
        return inferred

    return "auto"


def step_evidence_for_asset(asset: VideoAsset) -> dict[str, tuple[str, str]]:
    artifacts = artifact_paths_for_asset(asset)
    has_video = artifacts["video"].exists()
    has_remux = artifacts["remux_video"].exists()

    step_map: dict[str, tuple[str, str]] = {
        "download": ("pending", "Downloaded MP4 not found"),
        "extract": ("pending", "Awaiting transcript validation"),
        "transcribe": ("pending", "Awaiting transcript validation"),
        "translate": ("pending", "Awaiting translation validation"),
        "audiobook": ("pending", "Awaiting audiobook validation"),
        "remux": ("pending", "Awaiting remux validation"),
    }

    if has_video:
        if asset.source_url:
            download_ok, download_detail = _validate_downloaded_video(asset, artifacts["video"])
            if download_ok:
                step_map["download"] = ("success", download_detail)
            else:
                step_map["download"] = ("pending", download_detail)
        else:
            step_map["download"] = ("skipped", "Skipped: local MP4 already present")

    transcript_ok, transcript_detail = _can_reuse_transcript(artifacts["video"], artifacts["srt"])
    if transcript_ok:
        step_map["extract"] = ("skipped", "Skipped: transcript already covers source duration")
        step_map["transcribe"] = ("success", transcript_detail)
    else:
        step_map["extract"] = ("pending", transcript_detail)
        step_map["transcribe"] = ("pending", transcript_detail)

    source_lang = _infer_translation_source_lang_for_scan(asset, artifacts["video"])
    if source_lang in {"", "auto", "unknown"}:
        step_map["translate"] = (
            "pending",
            "Translation failed: unresolved source language; explicit source language is required",
        )
    elif transcript_ok:
        translation_ok, translation_detail = _can_reuse_translation(artifacts["srt"], artifacts["srtpt"])
        if translation_ok:
            step_map["translate"] = ("success", translation_detail)
        else:
            step_map["translate"] = ("pending", translation_detail)
    else:
        step_map["translate"] = ("pending", "Translation pending: transcript validation not satisfied")

    if step_map["translate"][0] == "success":
        audiobook_ok, audiobook_detail = _can_reuse_audiobook(
            artifacts["srt"],
            artifacts["srtpt"],
            artifacts["pt_wav"],
        )
        if audiobook_ok:
            step_map["audiobook"] = ("success", audiobook_detail)
        else:
            step_map["audiobook"] = ("pending", audiobook_detail)
    else:
        step_map["audiobook"] = ("pending", "Audiobook pending: translation validation not satisfied")

    if step_map["audiobook"][0] == "success" and has_remux:
        step_map["remux"] = ("success", "Evidence: remuxed video found in workdir/remux")
    elif step_map["audiobook"][0] == "success":
        step_map["remux"] = ("pending", "Remux output not found")
    else:
        step_map["remux"] = ("pending", "Remux pending: audiobook validation not satisfied")

    return step_map


def sync_run_steps_with_artifacts(asset: VideoAsset) -> None:
    evidence = step_evidence_for_asset(asset)
    run = latest_run_for_asset(asset, run_mode=RUN_MODE_PIPELINE)
    if run is None and not any(status in {"success", "skipped"} for status, _ in evidence.values()):
        return

    if run is None:
        run = _create_pipeline_run(asset, status="discovered")

    # Never override step states while a run is in-flight. During execution,
    # worker updates are the source of truth for UI progress.
    if run.status in {"queued", "running", "stopping"}:
        return

    step_changed = False
    for step_name in PIPELINE_STEP_ORDER:
        desired_status, detail = evidence[step_name]
        step, created = PipelineStepStatus.objects.get_or_create(
            pipeline_run=run,
            step_name=step_name,
            defaults={"status": "pending", "detail": ""},
        )

        if desired_status == "pending":
            if step.status != "pending" or step.detail != detail or step.started_at is not None or step.finished_at is not None:
                step.status = "pending"
                step.detail = detail
                step.started_at = None
                step.finished_at = None
                step.save(update_fields=["status", "detail", "started_at", "finished_at", "updated_at"])
                step_changed = True
            continue

        if created or step.status != desired_status or step.detail != detail:
            step.status = "pending"
            step.detail = detail
            step.save(update_fields=["status", "detail", "updated_at"])
            step_changed = True

    remux_completed = evidence["remux"][0] == "success"
    is_active = run.status in {"queued", "running", "stopping"}

    if remux_completed and (not is_active) and run.status != "success":
        run.status = "success"
        run.exit_code = 0
        run.error_message = ""
        if not run.finished_at:
            run.finished_at = timezone.now()
        run.save(update_fields=["status", "exit_code", "error_message", "finished_at", "updated_at"])
    elif (not remux_completed) and (not is_active) and run.status != "discovered":
        run.status = "discovered"
        run.exit_code = None
        run.finished_at = None
        run.error_message = ""
        run.save(update_fields=["status", "exit_code", "finished_at", "error_message", "updated_at"])
    elif step_changed:
        run.save(update_fields=["updated_at"])


def scan_videos() -> dict[str, int]:
    now = timezone.now()
    discovered = 0
    updated = 0
    work_exec = load_work_exec_dir()

    def _scan_directory(scan_dir: Path, storage_location: str, allow_archive: bool) -> None:
        nonlocal discovered, updated

        scan_dir.mkdir(parents=True, exist_ok=True)

        for path in sorted(scan_dir.iterdir()):
            if not path.is_file() or path.suffix.lower() not in VIDEO_EXTENSIONS:
                continue
            if is_generated_remux_sibling(path):
                continue

            defaults = {
                "file_name": path.name,
                "extension": path.suffix.lower(),
                "size_bytes": path.stat().st_size,
                "duration_seconds": ffprobe_duration_seconds(path),
                "discovered_at": now,
                "last_seen_at": now,
                "is_present": True,
                "storage_location": storage_location,
            }

            def _find_existing_asset() -> VideoAsset | None:
                return (
                    VideoAsset.objects.filter(
                        Q(file_name=path.name) | Q(file_path=path.name) | Q(file_path=str(path))
                    )
                    .order_by("id")
                    .first()
                )

            asset = _with_sqlite_lock_retry(_find_existing_asset)
            created = False
            if asset is None:
                asset = _with_sqlite_lock_retry(VideoAsset.objects.create, file_path=path.name, **defaults)
                created = True
            else:
                normalize_asset_storage_fields(asset)
                if asset.storage_location != storage_location:
                    asset.storage_location = storage_location
                    _with_sqlite_lock_retry(asset.save, update_fields=["storage_location"])
                if asset.is_deleted:
                    asset.is_deleted = False
                    _with_sqlite_lock_retry(asset.save, update_fields=["is_deleted"])
                for field_name, field_value in defaults.items():
                    setattr(asset, field_name, field_value)
                _with_sqlite_lock_retry(asset.save, update_fields=list(defaults.keys()))

            title_updates = _title_fields_for_asset(asset, path.name)
            if title_updates:
                for field_name, field_value in title_updates.items():
                    setattr(asset, field_name, field_value)
                _with_sqlite_lock_retry(asset.save, update_fields=list(title_updates.keys()))

            thumbnail_path = ensure_asset_thumbnail(asset)
            if thumbnail_path and thumbnail_path != asset.thumbnail_path:
                asset.thumbnail_path = thumbnail_path
                _with_sqlite_lock_retry(asset.save, update_fields=["thumbnail_path"])

            current_language = (asset.original_language or "").strip().lower()
            if current_language in {"", "auto", "unknown"}:
                inferred_lang = infer_language_from_srt(path)
                if inferred_lang and inferred_lang != asset.original_language:
                    asset.original_language = inferred_lang
                    _with_sqlite_lock_retry(asset.save, update_fields=["original_language"])

            _with_sqlite_lock_retry(ensure_execution_profile, asset)
            _with_sqlite_lock_retry(sync_run_steps_with_artifacts, asset)

            latest_run = latest_run_for_asset(asset, run_mode=RUN_MODE_PIPELINE)
            if allow_archive and storage_location == STORAGE_LOCATION_EXEC and latest_run and latest_run.status == "success":
                if archive_asset(asset):
                    updated += 1

            if created:
                discovered += 1
            else:
                updated += 1

    _scan_directory(work_exec, STORAGE_LOCATION_EXEC, allow_archive=True)
    _scan_directory(load_library_dir(), STORAGE_LOCATION_LIBRARY, allow_archive=False)

    for asset in _with_sqlite_lock_retry(
        lambda: list(
            VideoAsset.objects.filter(is_deleted=False).filter(
                Q(youtube_title_original="") | Q(youtube_title_pt_br="")
            )
        )
    ):
        title_updates = _title_fields_for_asset(asset, asset.file_name)
        if not title_updates:
            continue
        for field_name, field_value in title_updates.items():
            setattr(asset, field_name, field_value)
        _with_sqlite_lock_retry(asset.save, update_fields=list(title_updates.keys()))
        updated += 1

    unresolved_language_values = {"", "auto", "unknown"}
    for asset in _with_sqlite_lock_retry(lambda: list(VideoAsset.objects.filter(is_deleted=False))):
        storage_changed = normalize_asset_storage_fields(asset)
        update_fields: list[str] = []

        current_thumb = str(asset.thumbnail_path or "").strip()
        if not current_thumb:
            thumbnail_path = ensure_asset_thumbnail(asset)
            if thumbnail_path and thumbnail_path != asset.thumbnail_path:
                asset.thumbnail_path = thumbnail_path
                update_fields.append("thumbnail_path")

        current_language = (asset.original_language or "").strip().lower()
        if current_language in unresolved_language_values:
            inferred_lang = infer_language_from_srt(resolve_asset_video_path(asset))
            if inferred_lang and inferred_lang != asset.original_language:
                asset.original_language = inferred_lang
                update_fields.append("original_language")

        if update_fields:
            _with_sqlite_lock_retry(asset.save, update_fields=update_fields)
            updated += 1
        elif storage_changed:
            updated += 1

    try:
        export_scan_index_markdown(work_exec)
    except Exception:
        logger.exception("Failed to export scan index markdown")

    return {"discovered": discovered, "updated": updated, "missing": 0}


def delete_assets(video_ids: list[int]) -> int:
    if not video_ids:
        return 0

    active_asset_ids = set(
        PipelineRun.objects.filter(
            video_asset_id__in=video_ids,
            status__in=["queued", "running", "stopping"],
        ).values_list("video_asset_id", flat=True)
    )
    if active_asset_ids:
        raise ValueError("Nao e possivel excluir linhas com processamento ativo.")

    deleted = 0
    for asset in VideoAsset.objects.filter(id__in=video_ids, is_deleted=False):
        for candidate in related_asset_files(asset):
            try:
                if candidate.exists() and candidate.is_file():
                    candidate.unlink()
            except Exception:
                continue
        asset.is_deleted = True
        _with_sqlite_lock_retry(asset.save, update_fields=["is_deleted"])
        deleted += 1
    return deleted


def related_asset_files(asset: VideoAsset) -> list[Path]:
    canonical_name = canonical_asset_file_name(asset)
    if not canonical_name:
        return []

    stem = Path(canonical_name).stem
    suffix = Path(canonical_name).suffix
    stem_lower = stem.lower()
    suffix_lower = suffix.lower()
    storage_location = _asset_storage_location(asset)
    source_dirs = [load_library_dir()] if storage_location == STORAGE_LOCATION_LIBRARY else [load_work_exec_dir(), load_work_remux_dir()]
    matches: list[Path] = []
    seen: set[str] = set()

    for source_dir in source_dirs:
        if not source_dir.exists():
            continue
        try:
            for candidate in source_dir.iterdir():
                if not candidate.is_file():
                    continue
                candidate_key = str(candidate)
                if candidate_key in seen:
                    continue

                name_lower = candidate.name.lower()
                related = False
                if _is_related_asset_name(candidate.name, canonical_name, stem):
                    related = True
                elif source_dir == load_work_exec_dir() and candidate.name.startswith(f"{stem}."):
                    related = True
                elif candidate.suffix.lower() == suffix_lower and stem_lower in name_lower and "remux" in name_lower:
                    related = True

                if related:
                    matches.append(candidate)
                    seen.add(candidate_key)
        except Exception:
            continue

    return matches


def archive_asset(asset: VideoAsset) -> bool:
    if _asset_storage_location(asset) == STORAGE_LOCATION_LIBRARY:
        return False

    destination_dir = load_library_dir()
    moved_any = False
    for candidate in related_asset_files(asset):
        if not candidate.exists() or not candidate.is_file():
            continue
        destination = destination_dir / candidate.name
        destination = _next_available_destination(destination)
        shutil.move(str(candidate), str(destination))
        moved_any = True

    if moved_any:
        asset.storage_location = STORAGE_LOCATION_LIBRARY
        asset.is_present = True
        asset.last_seen_at = timezone.now()
        _with_sqlite_lock_retry(asset.save, update_fields=["storage_location", "is_present", "last_seen_at"])
    return moved_any


def restore_assets(video_ids: list[int]) -> int:
    if not video_ids:
        return 0

    restored = 0
    destination_dir = load_work_exec_dir()
    for asset in VideoAsset.objects.filter(id__in=video_ids, is_deleted=False):
        if _asset_storage_location(asset) != STORAGE_LOCATION_LIBRARY:
            continue

        sources = [candidate for candidate in related_asset_files(asset) if candidate.parent == load_library_dir()]
        if not sources:
            continue

        moved_any = False
        for source in sources:
            if not source.exists() or not source.is_file():
                continue
            destination = destination_dir / source.name
            destination = _next_available_destination(destination)
            shutil.move(str(source), str(destination))
            moved_any = True

        if not moved_any:
            continue

        asset.storage_location = STORAGE_LOCATION_EXEC
        asset.is_present = True
        asset.last_seen_at = timezone.now()
        _with_sqlite_lock_retry(asset.save, update_fields=["storage_location", "is_present", "last_seen_at"])

        latest_run = latest_run_for_asset(asset, run_mode=RUN_MODE_PIPELINE)
        if latest_run is None or latest_run.status in {"success", "failed", "stopped", "skipped"}:
            _create_pipeline_run(asset, status="discovered")

        restored += 1
    return restored


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
        qs = qs.filter(Q(file_name__in=file_names) | Q(file_path__in=file_names) | Q(file_path__in=path_set))

    synced = 0
    for asset in qs:
        sync_run_steps_with_artifacts(asset)
        synced += 1

    missing = 0
    # Housekeeping intentionally disabled: rows are kept until manual deletion.
    # if include_housekeeping:
    #     now = timezone.now()
    #     for asset in VideoAsset.objects.filter(is_present=True):
    #         if not Path(asset.file_path).exists():
    #             asset.is_present = False
    #             asset.last_seen_at = now
    #             asset.save(update_fields=["is_present", "last_seen_at"])
    #             missing += 1

    return {"synced": synced, "missing": missing}


def _collect_worker_health_status() -> dict[str, Any]:
    discovered = _discover_worker_processes()
    coordinator = _discover_coordinator_process()
    discovered_pids = [proc["pid"] for proc in discovered]

    queued = PipelineRun.objects.filter(status="queued").count()
    running = PipelineRun.objects.filter(status="running").count()
    stopping = PipelineRun.objects.filter(status="stopping").count()

    pid = discovered_pids[0] if discovered_pids else None
    scope_counts = {WORKER_SCOPE_GENERAL: 0, **{scope: 0 for scope in WORKER_STEP_SCOPES}}
    for proc in discovered:
        scope = str(proc.get("scope") or WORKER_SCOPE_GENERAL)
        scope_counts[scope] = scope_counts.get(scope, 0) + 1

    expected_slots_per_scope = {scope: worker_max_slots_per_scope() for scope in WORKER_STEP_SCOPES}
    expected_worker_count = sum(expected_slots_per_scope.values())

    return {
        "running": bool(discovered_pids),
        "coordinator_running": bool(coordinator),
        "coordinator_pid": coordinator["pid"] if coordinator else None,
        "coordinator": coordinator,
        "pid": pid,
        "source": "process_scan",
        "worker_pids": discovered_pids,
        "worker_count": len(discovered_pids),
        "worker_scope_counts": scope_counts,
        "expected_worker_slots_per_scope": expected_slots_per_scope,
        "expected_worker_count": expected_worker_count,
        "workers": discovered,
        "queue": {
            "queued": queued,
            "running": running,
            "stopping": stopping,
        },
    }


def _write_worker_status_snapshot(worker_payload: dict[str, Any], source: str) -> dict[str, Any]:
    run_dir = _worker_run_dir()
    run_dir.mkdir(parents=True, exist_ok=True)

    snapshot = {
        "collected_at": timezone.now().isoformat(),
        "source": str(source or "collector"),
        "worker": worker_payload,
    }

    target = _worker_status_snapshot_file()
    temp = target.with_suffix(".json.tmp")
    temp.write_text(json.dumps(snapshot, ensure_ascii=False, indent=2), encoding="utf-8")
    temp.replace(target)
    return snapshot


def _read_worker_status_snapshot() -> dict[str, Any] | None:
    path = _worker_status_snapshot_file()
    if not path.exists():
        return None

    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None

    if not isinstance(payload, dict):
        return None
    if not isinstance(payload.get("worker"), dict):
        return None
    return payload


def _ensure_pipeline_step_rows(run: PipelineRun) -> None:
    existing_step_names = set(run.steps.values_list("step_name", flat=True))
    for step_name in PIPELINE_STEP_ORDER:
        if step_name in existing_step_names:
            continue
        PipelineStepStatus.objects.create(pipeline_run=run, step_name=step_name, status="pending")


def _create_pipeline_run(asset: VideoAsset, *, status: str) -> PipelineRun:
    run = PipelineRun.objects.create(video_asset=asset, run_mode=RUN_MODE_PIPELINE, status=status)
    _ensure_pipeline_step_rows(run)
    return run


def collect_and_store_worker_health_snapshot(source: str = "collector") -> dict[str, Any]:
    worker_payload = _collect_worker_health_status()
    _write_worker_status_snapshot(worker_payload, source=source)
    return worker_payload


def worker_health_status() -> dict[str, Any]:
    stale_after_seconds = max(1, int(settings.WEBAPP.get("WORKER_STATUS_SNAPSHOT_STALE_SECONDS", 15)))
    snapshot = _read_worker_status_snapshot()
    if snapshot:
        collected_at = str(snapshot.get("collected_at") or "").strip()
        try:
            collected_dt = datetime.fromisoformat(collected_at)
            if timezone.is_naive(collected_dt):
                collected_dt = timezone.make_aware(collected_dt, timezone.get_current_timezone())
            age_seconds = (timezone.now() - collected_dt).total_seconds()
        except Exception:
            age_seconds = stale_after_seconds + 1

        if age_seconds <= stale_after_seconds:
            worker_payload = dict(snapshot["worker"])
            worker_payload["source"] = "snapshot"
            worker_payload["snapshot_source"] = snapshot.get("source")
            worker_payload["snapshot_collected_at"] = snapshot.get("collected_at")
            worker_payload["snapshot_age_seconds"] = max(0, int(age_seconds))
            return worker_payload

    worker_payload = _collect_worker_health_status()
    _write_worker_status_snapshot(worker_payload, source="api_fallback")
    worker_payload["source"] = "process_scan"
    return worker_payload


def active_run_exists(video_asset_id: int, run_mode: str | None = None) -> bool:
    qs = PipelineRun.objects.filter(video_asset_id=video_asset_id, status__in=["queued", "running", "stopping"])
    if run_mode:
        qs = qs.filter(run_mode=run_mode)
    return qs.exists()


def queue_runs(video_ids: list[int]) -> dict[str, Any]:
    queued_ids = []
    skipped = 0

    for video_id in video_ids:
        asset = VideoAsset.objects.filter(id=video_id, is_deleted=False).first()
        if asset is None or _asset_storage_location(asset) != STORAGE_LOCATION_EXEC:
            skipped += 1
            continue

        run = latest_run_for_asset(asset, run_mode=RUN_MODE_PIPELINE)
        if run is None:
            skipped += 1
            continue

        if run.status in {"queued", "running", "stopping"}:
            skipped += 1
            continue

        if run.status != "discovered":
            skipped += 1
            continue

        _ensure_pipeline_step_rows(run)
        run.status = "queued"
        run.started_at = None
        run.finished_at = None
        run.exit_code = None
        run.error_message = ""
        run.save(update_fields=["status", "started_at", "finished_at", "exit_code", "error_message", "updated_at"])
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


def update_execution_profile(video_id: int, payload: dict[str, Any]) -> ExecutionProfile:
    asset = VideoAsset.objects.get(id=video_id)
    return ensure_execution_profile(asset)


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
        "id": profile.id,
        "updated_at": profile.updated_at,
    }


def latest_run_for_asset(asset: VideoAsset, run_mode: str | None = None) -> PipelineRun | None:
    qs = asset.runs.all()
    if run_mode:
        qs = qs.filter(run_mode=run_mode)

    active_statuses = {"running", "queued", "stopping"}
    active_run = (
        qs.filter(status__in=active_statuses)
        .annotate(
            status_rank=Case(
                When(status="running", then=Value(0)),
                When(status="stopping", then=Value(1)),
                When(status="queued", then=Value(2)),
                default=Value(3),
                output_field=IntegerField(),
            )
        )
        .order_by(
            "status_rank",
            "-updated_at",
            "-created_at",
        )
        .first()
    )
    if active_run is not None:
        return active_run

    return qs.order_by("-created_at").first()


def _safe_log_tail(log_file_path: str | None) -> str:
    path = resolve_run_log_path(log_file_path)
    if path is None:
        return ""

    try:
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


def _progress_by_step_from_log(log_file_path: str | None) -> dict[str, int]:
    path = resolve_run_log_path(log_file_path)
    if path is None:
        return {}

    progress_by_step: dict[str, int] = {}
    progress_re = re.compile(r"\[progress\]\s+step=([a-zA-Z0-9_\-]+)\s+(\d+)%")

    try:
        if not path.exists() or (not path.is_file()):
            return {}

        with path.open("r", encoding="utf-8", errors="replace") as fh:
            for raw_line in fh:
                match = progress_re.search(raw_line)
                if not match:
                    continue

                step = match.group(1).strip().lower()
                try:
                    percent = int(match.group(2))
                except Exception:
                    continue

                percent = max(0, min(100, percent))
                current = progress_by_step.get(step, 0)
                if percent > current:
                    progress_by_step[step] = percent
    except Exception:
        return {}

    return progress_by_step


def serialize_asset(
    asset: VideoAsset,
    include_log_tail: bool = False,
    include_progress: bool = False,
) -> dict[str, Any]:
    normalize_asset_storage_fields(asset)
    normalize_asset_thumbnail_field(asset)
    profile = ensure_execution_profile(asset)
    latest_run = latest_run_for_asset(asset, run_mode=RUN_MODE_PIPELINE)

    steps = []
    if latest_run:
        steps = [
            {
                "step_name": s.step_name,
                "status": s.status,
                "detail": s.detail,
                "started_at": s.started_at.isoformat() if s.started_at else None,
                "finished_at": s.finished_at.isoformat() if s.finished_at else None,
                "duration_seconds": (
                    round((s.finished_at - s.started_at).total_seconds(), 3)
                    if s.started_at and s.finished_at
                    else None
                ),
                "updated_at": s.updated_at.isoformat(),
            }
            for s in latest_run.steps.order_by("id")
        ]

    latest_log_tail = _safe_log_tail(latest_run.log_file_path) if latest_run and include_log_tail else ""
    should_include_progress = bool(
        latest_run
        and (
            include_log_tail
            or (include_progress and latest_run.status in {"queued", "running", "stopping"})
        )
    )
    latest_progress_by_step = _progress_by_step_from_log(latest_run.log_file_path) if should_include_progress else {}
    resolved_thumb = resolve_asset_thumbnail_path(asset)
    has_real_thumbnail = bool(resolved_thumb and resolved_thumb.exists() and resolved_thumb.is_file())

    return {
        "id": asset.id,
        "file_path": str(resolve_asset_video_path(asset)),
        "file_name": asset.file_name,
        "source_url": asset.source_url,
        "thumbnail_url": f"/api/videos/{asset.id}/thumbnail",
        "has_real_thumbnail": has_real_thumbnail,
        "youtube_title_original": asset.youtube_title_original,
        "youtube_title_pt_br": asset.youtube_title_pt_br,
        "duration_seconds": asset.duration_seconds,
        "source_duration_seconds": asset.source_duration_seconds,
        "duration_hms": format_duration(asset.duration_seconds),
        "original_language": asset.original_language,
        "storage_location": asset.storage_location,
        "is_present": asset.is_present,
        "is_deleted": asset.is_deleted,
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
            "log_file_path": str(resolve_run_log_path(latest_run.log_file_path) or ""),
            "log_url": f"/api/runs/{latest_run.id}/log",
            "log_tail": latest_log_tail,
            "progress_by_step": latest_progress_by_step,
            "steps": steps,
        }
        if latest_run
        else None,
    }


def list_assets(
    present_only: bool = True,
    include_active_runs: bool = False,
    include_log_tail: bool = False,
    include_progress: bool = False,
) -> list[dict[str, Any]]:
    qs = VideoAsset.objects.filter(is_deleted=False).order_by("file_name")

    items = []
    for asset in qs:
        if is_generated_remux_sibling(Path(canonical_asset_file_name(asset))):
            continue
        items.append(
            serialize_asset(
                asset,
                include_log_tail=include_log_tail,
                include_progress=include_progress,
            )
        )
    return items
