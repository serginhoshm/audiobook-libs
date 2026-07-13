import os
import re
import select
import shutil
import signal
import subprocess
import sys
import time
import json
from pathlib import Path
from typing import Any
from urllib import error as urlerror
from urllib import parse as urlparse
from urllib import request as urlrequest

from django.conf import settings
from django.utils import timezone

from .models import ExecutionProfile, PipelineRun, PipelineStepStatus
from .services import (
    DOWNLOAD_DURATION_TOLERANCE_SECONDS,
    RUN_MODE_PIPELINE,
    ffprobe_duration_seconds,
    infer_language_from_srt,
    load_data_root,
)


PIPELINE_STEP_ORDER = ["download", "extract", "transcribe", "translate", "audiobook", "remux"]
SRT_RANGE_PATTERN = re.compile(
    r"(\d{2}):(\d{2}):(\d{2})[,.](\d{3})\s*-->\s*(\d{2}):(\d{2}):(\d{2})[,.](\d{3})"
)
VIDEO_SRT_REUSE_TOLERANCE_SECONDS = 4.0
TRANSLATION_REUSE_TOLERANCE_SECONDS = 1.5
LANGUAGE_SAMPLE_MAX_CHARS = 100
LANGUAGE_DETECT_TIMEOUT_SECONDS = 8

NLLB_LANG_MAP = {
    "ar": "arb_Arab",
    "de": "deu_Latn",
    "en": "eng_Latn",
    "es": "spa_Latn",
    "fr": "fra_Latn",
    "hi": "hin_Deva",
    "it": "ita_Latn",
    "ja": "jpn_Jpan",
    "ko": "kor_Hang",
    "nl": "nld_Latn",
    "pl": "pol_Latn",
    "pt": "por_Latn",
    "ru": "rus_Cyrl",
    "tr": "tur_Latn",
    "uk": "ukr_Cyrl",
    "zh": "zho_Hans",
    "zh-cn": "zho_Hans",
    "zh-hans": "zho_Hans",
}

TRANSLATION_SOURCE_BY_NLLB = {
    "arb_Arab": "ar",
    "deu_Latn": "de",
    "eng_Latn": "en",
    "fra_Latn": "fr",
    "hin_Deva": "hi",
    "ita_Latn": "it",
    "jpn_Jpan": "ja",
    "kor_Hang": "ko",
    "nld_Latn": "nl",
    "pol_Latn": "pl",
    "por_Latn": "pt",
    "rus_Cyrl": "ru",
    "spa_Latn": "es",
    "tur_Latn": "tr",
    "ukr_Cyrl": "uk",
    "zho_Hans": "zh-CN",
}


def _bool_to_on_off(value: bool) -> str:
    return "on" if value else "off"


def _resolve_video_path_for_run(run: PipelineRun) -> str:
    return run.video_asset.file_path


def build_exec_command(profile: ExecutionProfile) -> list[str]:
    root_dir = Path(settings.WEBAPP["ROOT_DIR"])
    python_bin = root_dir / ".venv" / "bin" / "python"
    if python_bin.exists():
        return [str(python_bin)]
    return [sys.executable]


def _infer_source_lang(run: PipelineRun, video_path: Path) -> str:
    lang = (run.video_asset.original_language or "auto").strip()
    if lang in {"es", "zh-CN", "auto"}:
        return lang
    if lang in TRANSLATION_SOURCE_BY_NLLB:
        return TRANSLATION_SOURCE_BY_NLLB[lang]
    name = video_path.name.lower()
    if "spanish" in name:
        return "es"
    if "chinese" in name:
        return "zh-CN"
    return "auto"


def _infer_translation_source_lang(run: PipelineRun, video_path: Path, srt_path: Path) -> str:
    persisted = (run.video_asset.original_language or "").strip()
    if persisted in TRANSLATION_SOURCE_BY_NLLB:
        return TRANSLATION_SOURCE_BY_NLLB[persisted]

    lang = _infer_source_lang(run, video_path)
    if lang in {"es", "zh-CN"}:
        return lang

    inferred_from_srt = infer_language_from_srt(video_path)
    if inferred_from_srt in {"es", "zh-CN"}:
        return inferred_from_srt

    return "auto"


def _extract_language_sample_from_srt(srt_path: Path, max_chars: int = LANGUAGE_SAMPLE_MAX_CHARS) -> str:
    if not srt_path.exists():
        return ""

    parts: list[str] = []
    remaining = max_chars
    try:
        with open(srt_path, "r", encoding="utf-8", errors="ignore") as fh:
            for raw_line in fh:
                line = raw_line.strip()
                if (not line) or line.isdigit() or ("-->" in line):
                    continue
                snippet = line[:remaining]
                parts.append(snippet)
                remaining -= len(snippet)
                if remaining <= 0:
                    break
    except Exception:
        return ""

    return " ".join(parts).strip()[:max_chars]


def _detect_language_with_google(sample_text: str) -> str | None:
    if not sample_text:
        return None

    query = urlparse.urlencode(
        {
            "client": "gtx",
            "sl": "auto",
            "tl": "pt",
            "dt": "t",
            "q": sample_text,
        }
    )
    endpoint = f"https://translate.googleapis.com/translate_a/single?{query}"
    req = urlrequest.Request(endpoint, headers={"User-Agent": "Mozilla/5.0"}, method="GET")

    try:
        with urlrequest.urlopen(req, timeout=LANGUAGE_DETECT_TIMEOUT_SECONDS) as resp:
            payload = resp.read().decode("utf-8", errors="replace")
        data = json.loads(payload)
    except (urlerror.URLError, TimeoutError, json.JSONDecodeError, ValueError):
        return None
    except Exception:
        return None

    # Google translate public endpoint returns detected language at index 2.
    if isinstance(data, list) and len(data) >= 3 and isinstance(data[2], str):
        detected = data[2].strip().lower()
        return detected or None
    return None


def _map_to_nllb_code(detected_lang: str | None) -> str:
    if not detected_lang:
        return "unknown"
    normalized = detected_lang.strip().lower()
    if not normalized:
        return "unknown"

    direct = NLLB_LANG_MAP.get(normalized)
    if direct:
        return direct

    primary = normalized.split("-")[0]
    return NLLB_LANG_MAP.get(primary, "unknown")


def _persist_detected_language_from_srt(run: PipelineRun, srt_path: Path, log_fh: Any) -> str:
    sample = _extract_language_sample_from_srt(srt_path)
    if not sample:
        run.video_asset.original_language = "unknown"
        run.video_asset.save(update_fields=["original_language"])
        log_fh.write("[language] detection sample unavailable; original_language=unknown\n")
        log_fh.flush()
        return "unknown"

    detected_lang = _detect_language_with_google(sample)
    nllb_code = _map_to_nllb_code(detected_lang)
    run.video_asset.original_language = nllb_code
    run.video_asset.save(update_fields=["original_language"])
    if detected_lang:
        log_fh.write(f"[language] detected={detected_lang} nllb={nllb_code}\n")
    else:
        log_fh.write("[language] detection failed; original_language=unknown\n")
    log_fh.flush()
    return nllb_code


def _whisper_lang_from_source(source_lang: str) -> str:
    if source_lang == "es":
        return "es"
    if source_lang == "zh-CN":
        return "zh"
    return "auto"


def _yt_dlp_js_runtime_args() -> list[str]:
    for runtime in ("deno", "node"):
        runtime_path = shutil.which(runtime)
        if runtime_path:
            return ["--js-runtimes", f"{runtime}:{runtime_path}"]
    raise RuntimeError(
        "yt-dlp requires a JavaScript runtime for YouTube extraction. "
        "Install deno or node, then try again."
    )


def _download_target_is_valid(run: PipelineRun, video_path: Path) -> tuple[bool, str]:
    source_duration = run.video_asset.source_duration_seconds
    if not video_path.exists():
        return False, "Downloaded MP4 not found"

    local_duration = ffprobe_duration_seconds(video_path)
    if local_duration is None:
        return False, "Unable to read downloaded MP4 duration"

    if source_duration is None:
        return True, f"Downloaded MP4 present with duration {local_duration:.1f}s"

    delta = abs(local_duration - source_duration)
    if delta <= DOWNLOAD_DURATION_TOLERANCE_SECONDS:
        return True, (
            "Downloaded MP4 duration matches source duration: "
            f"local {local_duration:.1f}s vs source {source_duration:.1f}s"
        )

    return False, (
        "Downloaded MP4 duration mismatch: "
        f"local {local_duration:.1f}s vs source {source_duration:.1f}s"
    )


def _persist_download_result(run: PipelineRun, video_path: Path) -> tuple[bool, str]:
    ok, detail = _download_target_is_valid(run, video_path)
    if ok:
        try:
            run.video_asset.duration_seconds = ffprobe_duration_seconds(video_path)
            run.video_asset.size_bytes = video_path.stat().st_size
            run.video_asset.file_name = video_path.name
            run.video_asset.file_path = str(video_path)
            run.video_asset.extension = video_path.suffix.lower()
            run.video_asset.is_present = True
            run.video_asset.last_seen_at = timezone.now()
            run.video_asset.save(
                update_fields=[
                    "duration_seconds",
                    "size_bytes",
                    "file_name",
                    "file_path",
                    "extension",
                    "is_present",
                    "last_seen_at",
                ]
            )
        except Exception:
            pass
    return ok, detail


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


def _run_subprocess_with_streaming(
    run: PipelineRun,
    command: list[str],
    log_fh: Any,
    cwd: Path,
) -> int:
    grace = int(settings.WEBAPP["WORKER_GRACE_SECONDS"])

    proc = subprocess.Popen(
        command,
        cwd=str(cwd),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
        preexec_fn=os.setsid,
    )

    run.pid = proc.pid
    try:
        run.process_group_id = os.getpgid(proc.pid)
    except Exception:
        run.process_group_id = None
    run.save(update_fields=["pid", "process_group_id", "updated_at"])

    stdout_stream = proc.stdout
    rc: int | None = None

    while True:
        if stdout_stream:
            ready, _, _ = select.select([stdout_stream], [], [], 0.8)
            if ready:
                line = stdout_stream.readline()
                if line:
                    log_fh.write(line)
                    log_fh.flush()

        rc = proc.poll()
        run.refresh_from_db(fields=["stop_requested", "status"])
        if rc is not None:
            break

        if run.stop_requested or run.status == "stopping":
            _signal_process_group(run.process_group_id or proc.pid, signal.SIGTERM)
            waited = 0
            while waited < grace:
                rc = proc.poll()
                if rc is not None:
                    break
                time.sleep(1)
                waited += 1
            if rc is None:
                _signal_process_group(run.process_group_id or proc.pid, signal.SIGKILL)
                rc = proc.wait(timeout=10)
            break

    if stdout_stream:
        for line in stdout_stream:
            log_fh.write(line)
            log_fh.flush()

    return int(rc if rc is not None else 1)


def _execute_pipeline_steps(
    run: PipelineRun,
    profile: ExecutionProfile,
    video_path: Path,
    root_dir: Path,
    log_fh: Any,
) -> tuple[int, str]:
    python_cmd = build_exec_command(profile)
    scripts_dir = root_dir / "scripts"
    model_path = root_dir / "models" / "pt_BR-faber-medium.onnx"
    piper_bin = root_dir / "bin" / "piper"

    if not model_path.exists():
        return 127, f"Voice model not found: {model_path}"
    if not piper_bin.exists():
        return 127, f"Piper executable not found: {piper_bin}"

    pre_transcribe_source_lang = _infer_source_lang(run, video_path)
    whisper_lang = _whisper_lang_from_source(pre_transcribe_source_lang)

    base_name = video_path.stem
    work_dir = video_path.parent
    wav_path = work_dir / f"{base_name}.wav"
    srt_path = work_dir / f"{base_name}.srt"
    srtpt_path = work_dir / f"{base_name}.srtpt"
    out_wav_path = work_dir / f"{base_name}.pt.wav"

    backend = profile.backend
    if backend == "libretranslate":
        # Legacy rows may still carry libretranslate; route them to google by default.
        backend = "google"
        log_fh.write("[worker] legacy backend libretranslate detected; using google\n")

    download_step = run.steps.filter(step_name="download").first()
    if download_step and download_step.status == "pending":
        if video_path.exists() and not run.video_asset.source_url:
            _set_step_status(run.id, "download", "skipped", "Skipped: local MP4 already present")
        elif video_path.exists() and run.video_asset.source_url:
            ok, detail = _persist_download_result(run, video_path)
            _set_step_status(run.id, "download", "success" if ok else "failed", detail)

    if not video_path.exists() and run.video_asset.source_url:
        log_fh.write("step 0 - download\n")
        log_fh.flush()
        _set_step_status(run.id, "download", "running", "step 0 - download")
        try:
            download_cmd = [
                "yt-dlp",
                "--no-playlist",
                "--continue",
                "--merge-output-format",
                "mp4",
                "--remote-components",
                "ejs:github",
                *_yt_dlp_js_runtime_args(),
                "-f",
                "bv*[height>=480][height<=720]+ba/b[height>=480][height<=720]",
                "-o",
                f"{video_path.with_suffix('')}.%(ext)s",
                run.video_asset.source_url,
            ]
        except RuntimeError as exc:
            _set_step_status(run.id, "download", "failed", str(exc))
            return 2, str(exc)
        rc = _run_subprocess_with_streaming(run, download_cmd, log_fh, root_dir)
        if rc != 0:
            _set_step_status(run.id, "download", "failed", "Download failed")
            return rc, "Download failed"

        ok, detail = _persist_download_result(run, video_path)
        _set_step_status(run.id, "download", "success" if ok else "failed", detail)
        if not ok:
            return 2, detail
    elif video_path.exists() and run.video_asset.source_url:
        ok, detail = _persist_download_result(run, video_path)
        if ok:
            _set_step_status(run.id, "download", "success", detail)
        else:
            _set_step_status(run.id, "download", "failed", detail)
            return 2, detail
    elif video_path.exists():
        _set_step_status(run.id, "download", "skipped", "Skipped: local MP4 already present")

    if not video_path.exists():
        return 127, f"Input video not found: {video_path}"

    reuse_transcript, transcript_detail = _can_reuse_transcript(video_path, srt_path)
    if reuse_transcript:
        log_fh.write(f"step 1 - extract skipped ({transcript_detail})\n")
        log_fh.write(f"step 2 - transcribe skipped ({transcript_detail})\n")
        log_fh.flush()
        _set_step_status(run.id, "extract", "skipped", "Skipped: transcript already covers source duration")
        _set_step_status(run.id, "transcribe", "success", transcript_detail)
        _persist_detected_language_from_srt(run, srt_path, log_fh)
    else:
        log_fh.write(f"{transcript_detail}\n")
        log_fh.write("step 1 - extract\n")
        log_fh.flush()
        _set_step_status(run.id, "extract", "running", "step 1 - extract")
        extract_cmd = [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(video_path),
            "-vn",
            str(wav_path),
        ]
        rc = _run_subprocess_with_streaming(run, extract_cmd, log_fh, root_dir)
        if rc != 0:
            _set_step_status(run.id, "extract", "failed", "Audio extraction failed")
            return rc, "Audio extraction failed"
        _set_step_status(run.id, "extract", "success", "Completed successfully")

        log_fh.write("step 2 - transcribe\n")
        log_fh.flush()
        _set_step_status(run.id, "transcribe", "running", "step 2 - transcribe")
        transcribe_cmd = [
            *python_cmd,
            str(scripts_dir / "transcrever.py"),
            str(wav_path),
            str(work_dir),
            whisper_lang,
            "medium",
            base_name,
        ]
        rc = _run_subprocess_with_streaming(run, transcribe_cmd, log_fh, root_dir)
        if rc != 0:
            _set_step_status(run.id, "transcribe", "failed", "Transcription failed")
            return rc, "Transcription failed"
        _set_step_status(run.id, "transcribe", "success", "Completed successfully")
        _persist_detected_language_from_srt(run, srt_path, log_fh)

    source_lang = _infer_translation_source_lang(run, video_path, srt_path)
    reuse_translation, translation_detail = _can_reuse_translation(srt_path, srtpt_path)
    if reuse_translation and source_lang != "auto":
        log_fh.write(f"step 2 - translate skipped ({translation_detail})\n")
        log_fh.write(f"[translation] source_lang={source_lang} backend={backend}\n")
        log_fh.flush()
        _set_step_status(run.id, "translate", "success", translation_detail)
    else:
        if reuse_translation and source_lang == "auto":
            log_fh.write(
                "[translation] source language unresolved; forcing translator detection before reuse\n"
            )
        log_fh.write(f"{translation_detail}\n")
        log_fh.write("step 3 - translate\n")
        log_fh.write(f"[translation] source_lang={source_lang} backend={backend}\n")
        if backend == "deepl_doc":
            log_fh.write(
                f"[DEEPL_ROTATION_MODE] profile_backend=deepl_doc endpoint={profile.deepl_endpoint} "
                "fallback=google_on_exhausted_keys\n"
            )
        log_fh.flush()
        _set_step_status(run.id, "translate", "running", "step 3 - translate")
        translate_cmd = [
            *python_cmd,
            str(scripts_dir / "traduzir.py"),
            str(srt_path),
            str(srtpt_path),
            source_lang,
            "--backend",
            backend,
            "--deepl-endpoint",
            profile.deepl_endpoint,
            "--deepl-keys-ini",
            str(root_dir / "config" / "translation" / "deepl_keys.ini"),
            "--deepl-keys-state-ini",
            str(root_dir / "config" / "translation" / "deepl_keys_state.ini"),
            "--nllb-max-input-length",
            str(profile.nllb_max_input_length),
            "--nllb-max-new-tokens",
            str(profile.nllb_max_new_tokens),
        ]
        if profile.nllb_legacy:
            translate_cmd.append("--nllb-legacy-generation")

        rc = _run_subprocess_with_streaming(run, translate_cmd, log_fh, root_dir)
        if rc != 0:
            _set_step_status(run.id, "translate", "failed", "Translation failed")
            return rc, "Translation failed"
        _set_step_status(run.id, "translate", "success", "Completed successfully")

    log_fh.write("step 4 - wav generation (piper)\n")
    log_fh.flush()
    _set_step_status(run.id, "audiobook", "running", "step 4 - wav generation (piper)")
    synth_cmd = [
        *python_cmd,
        str(scripts_dir / "gerar-sincronizado.py"),
        "--srt",
        str(srtpt_path),
        "--output",
        str(out_wav_path),
        "--model",
        str(model_path),
        "--piper",
        str(piper_bin),
        "--source_lang",
        source_lang,
        "--pause_duration",
        "0.1",
    ]

    rc = _run_subprocess_with_streaming(run, synth_cmd, log_fh, root_dir)
    if rc != 0:
        _set_step_status(run.id, "audiobook", "failed", "Audiobook synthesis failed")
        return rc, "Audiobook synthesis failed"
    _set_step_status(run.id, "audiobook", "success", "Completed successfully")

    log_fh.write("step 5 - remux generation\n")
    log_fh.flush()
    _set_step_status(run.id, "remux", "running", "step 5 - remux generation")

    video_ext = video_path.suffix if video_path.suffix else ".mp4"
    remux_out = video_path.with_name(f"{base_name} (remux){video_ext}")

    remux_cmd = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-i",
        str(video_path),
        "-i",
        str(out_wav_path),
        "-map",
        "0:v:0",
        "-map",
        "1:a:0",
        "-c:v",
        "copy",
        "-c:a",
        "aac",
        "-shortest",
        str(remux_out),
    ]

    rc = _run_subprocess_with_streaming(run, remux_cmd, log_fh, root_dir)
    if rc != 0:
        _set_step_status(run.id, "remux", "failed", "Remux generation failed")
        return rc, "Remux generation failed"

    log_fh.write("remux generated successfully\n")
    log_fh.flush()
    _set_step_status(run.id, "remux", "success", "Completed successfully")

    return 0, ""


def ensure_webapp_log_dir() -> Path:
    log_dir = Path(settings.WEBAPP["WEBAPP_LOG_DIR"])
    log_dir.mkdir(parents=True, exist_ok=True)
    return log_dir


def _signal_process_group(pgid: int, sig: int) -> None:
    try:
        os.killpg(pgid, sig)
    except ProcessLookupError:
        return


def request_stop(run: PipelineRun) -> None:
    if not run.process_group_id:
        return
    _signal_process_group(run.process_group_id, signal.SIGTERM)


def _ensure_step_rows(run: PipelineRun) -> None:
    for step_name in PIPELINE_STEP_ORDER:
        PipelineStepStatus.objects.get_or_create(
            pipeline_run=run,
            step_name=step_name,
            defaults={"status": "pending", "detail": ""},
        )


def _reset_step_rows_for_attempt(run: PipelineRun) -> None:
    PipelineStepStatus.objects.filter(pipeline_run=run, step_name__in=PIPELINE_STEP_ORDER).update(
        status="pending",
        detail="",
        updated_at=timezone.now(),
    )


def _set_step_status(run_id: int, step_name: str, status: str, detail: str = "") -> None:
    PipelineStepStatus.objects.filter(pipeline_run_id=run_id, step_name=step_name).update(
        status=status,
        detail=detail,
        updated_at=timezone.now(),
    )


def _step_status_map(run: PipelineRun) -> dict[str, str]:
    return {step.step_name: step.status for step in run.steps.all()}


def _next_pending_step_name(run: PipelineRun) -> str | None:
    status_map = _step_status_map(run)
    for step_name in PIPELINE_STEP_ORDER:
        if status_map.get(step_name, "pending") not in {"success", "skipped"}:
            return step_name
    return None


def _execute_pipeline_single_step(
    run: PipelineRun,
    profile: ExecutionProfile,
    video_path: Path,
    root_dir: Path,
    log_fh: Any,
    target_step: str,
) -> tuple[int, str]:
    python_cmd = build_exec_command(profile)
    scripts_dir = root_dir / "scripts"
    model_path = root_dir / "models" / "pt_BR-faber-medium.onnx"
    piper_bin = root_dir / "bin" / "piper"

    base_name = video_path.stem
    work_dir = video_path.parent
    wav_path = work_dir / f"{base_name}.wav"
    srt_path = work_dir / f"{base_name}.srt"
    srtpt_path = work_dir / f"{base_name}.srtpt"
    out_wav_path = work_dir / f"{base_name}.pt.wav"

    backend = profile.backend
    if backend == "libretranslate":
        backend = "google"
        log_fh.write("[worker] legacy backend libretranslate detected; using google\n")

    if target_step == "download":
        if video_path.exists() and not run.video_asset.source_url:
            _set_step_status(run.id, "download", "skipped", "Skipped: local MP4 already present")
            return 0, ""

        if video_path.exists() and run.video_asset.source_url:
            ok, detail = _persist_download_result(run, video_path)
            _set_step_status(run.id, "download", "success" if ok else "failed", detail)
            return (0, "") if ok else (2, detail)

        if not run.video_asset.source_url:
            _set_step_status(run.id, "download", "failed", "Input video not found and no source URL available")
            return 127, f"Input video not found: {video_path}"

        log_fh.write("step 0 - download\n")
        log_fh.flush()
        _set_step_status(run.id, "download", "running", "step 0 - download")
        try:
            download_cmd = [
                "yt-dlp",
                "--no-playlist",
                "--continue",
                "--merge-output-format",
                "mp4",
                "--remote-components",
                "ejs:github",
                *_yt_dlp_js_runtime_args(),
                "-f",
                "bv*[height>=480][height<=720]+ba/b[height>=480][height<=720]",
                "-o",
                f"{video_path.with_suffix('')}.%(ext)s",
                run.video_asset.source_url,
            ]
        except RuntimeError as exc:
            _set_step_status(run.id, "download", "failed", str(exc))
            return 2, str(exc)

        rc = _run_subprocess_with_streaming(run, download_cmd, log_fh, root_dir)
        if rc != 0:
            _set_step_status(run.id, "download", "failed", "Download failed")
            return rc, "Download failed"

        ok, detail = _persist_download_result(run, video_path)
        _set_step_status(run.id, "download", "success" if ok else "failed", detail)
        return (0, "") if ok else (2, detail)

    if not video_path.exists():
        return 127, f"Input video not found: {video_path}"

    if target_step == "extract":
        reuse_transcript, transcript_detail = _can_reuse_transcript(video_path, srt_path)
        if reuse_transcript:
            log_fh.write(f"step 1 - extract skipped ({transcript_detail})\n")
            log_fh.flush()
            _set_step_status(run.id, "extract", "skipped", "Skipped: transcript already covers source duration")
            return 0, ""

        log_fh.write(f"{transcript_detail}\n")
        log_fh.write("step 1 - extract\n")
        log_fh.flush()
        _set_step_status(run.id, "extract", "running", "step 1 - extract")
        extract_cmd = [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(video_path),
            "-vn",
            str(wav_path),
        ]
        rc = _run_subprocess_with_streaming(run, extract_cmd, log_fh, root_dir)
        if rc != 0:
            _set_step_status(run.id, "extract", "failed", "Audio extraction failed")
            return rc, "Audio extraction failed"
        _set_step_status(run.id, "extract", "success", "Completed successfully")
        return 0, ""

    if target_step == "transcribe":
        pre_transcribe_source_lang = _infer_source_lang(run, video_path)
        whisper_lang = _whisper_lang_from_source(pre_transcribe_source_lang)

        reuse_transcript, transcript_detail = _can_reuse_transcript(video_path, srt_path)
        if reuse_transcript:
            log_fh.write(f"step 2 - transcribe skipped ({transcript_detail})\n")
            log_fh.flush()
            _set_step_status(run.id, "transcribe", "success", transcript_detail)
            _persist_detected_language_from_srt(run, srt_path, log_fh)
            return 0, ""

        if not wav_path.exists():
            _set_step_status(run.id, "transcribe", "failed", "Audio input missing: run extract first")
            return 2, "Audio input missing: run extract first"

        log_fh.write(f"{transcript_detail}\n")
        log_fh.write("step 2 - transcribe\n")
        log_fh.flush()
        _set_step_status(run.id, "transcribe", "running", "step 2 - transcribe")
        transcribe_cmd = [
            *python_cmd,
            str(scripts_dir / "transcrever.py"),
            str(wav_path),
            str(work_dir),
            whisper_lang,
            "medium",
            base_name,
        ]
        rc = _run_subprocess_with_streaming(run, transcribe_cmd, log_fh, root_dir)
        if rc != 0:
            _set_step_status(run.id, "transcribe", "failed", "Transcription failed")
            return rc, "Transcription failed"
        _set_step_status(run.id, "transcribe", "success", "Completed successfully")
        _persist_detected_language_from_srt(run, srt_path, log_fh)
        return 0, ""

    if target_step == "translate":
        source_lang = _infer_translation_source_lang(run, video_path, srt_path)
        reuse_translation, translation_detail = _can_reuse_translation(srt_path, srtpt_path)
        if reuse_translation and source_lang != "auto":
            log_fh.write(f"step 3 - translate skipped ({translation_detail})\n")
            log_fh.write(f"[translation] source_lang={source_lang} backend={backend}\n")
            log_fh.flush()
            _set_step_status(run.id, "translate", "success", translation_detail)
            return 0, ""

        if not srt_path.exists():
            _set_step_status(run.id, "translate", "failed", "Source SRT missing: run transcribe first")
            return 2, "Source SRT missing: run transcribe first"

        if reuse_translation and source_lang == "auto":
            log_fh.write("[translation] source language unresolved; forcing translator detection before reuse\n")
        log_fh.write(f"{translation_detail}\n")
        log_fh.write("step 3 - translate\n")
        log_fh.write(f"[translation] source_lang={source_lang} backend={backend}\n")
        if backend == "deepl_doc":
            log_fh.write(
                f"[DEEPL_ROTATION_MODE] profile_backend=deepl_doc endpoint={profile.deepl_endpoint} "
                "fallback=google_on_exhausted_keys\n"
            )
        log_fh.flush()
        _set_step_status(run.id, "translate", "running", "step 3 - translate")
        translate_cmd = [
            *python_cmd,
            str(scripts_dir / "traduzir.py"),
            str(srt_path),
            str(srtpt_path),
            source_lang,
            "--backend",
            backend,
            "--deepl-endpoint",
            profile.deepl_endpoint,
            "--deepl-keys-ini",
            str(root_dir / "config" / "translation" / "deepl_keys.ini"),
            "--deepl-keys-state-ini",
            str(root_dir / "config" / "translation" / "deepl_keys_state.ini"),
            "--nllb-max-input-length",
            str(profile.nllb_max_input_length),
            "--nllb-max-new-tokens",
            str(profile.nllb_max_new_tokens),
        ]
        if profile.nllb_legacy:
            translate_cmd.append("--nllb-legacy-generation")

        rc = _run_subprocess_with_streaming(run, translate_cmd, log_fh, root_dir)
        if rc != 0:
            _set_step_status(run.id, "translate", "failed", "Translation failed")
            return rc, "Translation failed"
        _set_step_status(run.id, "translate", "success", "Completed successfully")
        return 0, ""

    if target_step == "audiobook":
        if not model_path.exists():
            return 127, f"Voice model not found: {model_path}"
        if not piper_bin.exists():
            return 127, f"Piper executable not found: {piper_bin}"
        if not srtpt_path.exists():
            _set_step_status(run.id, "audiobook", "failed", "Translated SRTPT missing: run translate first")
            return 2, "Translated SRTPT missing: run translate first"

        source_lang = _infer_translation_source_lang(run, video_path, srt_path)
        log_fh.write("step 4 - wav generation (piper)\n")
        log_fh.flush()
        _set_step_status(run.id, "audiobook", "running", "step 4 - wav generation (piper)")
        synth_cmd = [
            *python_cmd,
            str(scripts_dir / "gerar-sincronizado.py"),
            "--srt",
            str(srtpt_path),
            "--output",
            str(out_wav_path),
            "--model",
            str(model_path),
            "--piper",
            str(piper_bin),
            "--source_lang",
            source_lang,
            "--pause_duration",
            "0.1",
        ]
        rc = _run_subprocess_with_streaming(run, synth_cmd, log_fh, root_dir)
        if rc != 0:
            _set_step_status(run.id, "audiobook", "failed", "Audiobook synthesis failed")
            return rc, "Audiobook synthesis failed"
        _set_step_status(run.id, "audiobook", "success", "Completed successfully")
        return 0, ""

    if target_step == "remux":
        if not out_wav_path.exists():
            _set_step_status(run.id, "remux", "failed", "PT WAV missing: run audiobook first")
            return 2, "PT WAV missing: run audiobook first"

        log_fh.write("step 5 - remux generation\n")
        log_fh.flush()
        _set_step_status(run.id, "remux", "running", "step 5 - remux generation")

        video_ext = video_path.suffix if video_path.suffix else ".mp4"
        remux_out = video_path.with_name(f"{base_name} (remux){video_ext}")

        remux_cmd = [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(video_path),
            "-i",
            str(out_wav_path),
            "-map",
            "0:v:0",
            "-map",
            "1:a:0",
            "-c:v",
            "copy",
            "-c:a",
            "aac",
            "-shortest",
            str(remux_out),
        ]

        rc = _run_subprocess_with_streaming(run, remux_cmd, log_fh, root_dir)
        if rc != 0:
            _set_step_status(run.id, "remux", "failed", "Remux generation failed")
            return rc, "Remux generation failed"

        log_fh.write("remux generated successfully\n")
        log_fh.flush()
        _set_step_status(run.id, "remux", "success", "Completed successfully")
        return 0, ""

    return 2, f"Unsupported step: {target_step}"


def _promote_step_from_log_line(run_id: int, line: str, current_step: str | None) -> str | None:
    text = line.strip()
    lower = text.lower()

    if "step 0 - download" in lower:
        _set_step_status(run_id, "download", "running", text)
        return "download"
    if "step 1 - extract" in lower:
        _set_step_status(run_id, "extract", "running", text)
        return "extract"
    if "step 2 - transcribe" in lower:
        _set_step_status(run_id, "transcribe", "running", text)
        return "transcribe"
    if "step 3 - translate" in lower:
        _set_step_status(run_id, "translate", "running", text)
        return "translate"
    if "step 4" in lower or "wav generation (piper)" in lower:
        _set_step_status(run_id, "audiobook", "running", text)
        return "audiobook"

    if "step 5" in lower or "remux generation" in lower or ("processing video" in lower and "remux" in lower):
        _set_step_status(run_id, "remux", "running", text)
        return "remux"

    if "remux generated successfully" in lower:
        _set_step_status(run_id, "remux", "success", text)
        return "remux"

    if "download failed" in lower:
        _set_step_status(run_id, "download", "failed", text)
        return "download"

    if "translated srt not generated/validated" in lower:
        _set_step_status(run_id, "translate", "failed", text)
        return "translate"

    if "wav/pt.wav not generated/validated" in lower or ("audio" in lower and "not generated/validated" in lower):
        _set_step_status(run_id, "audiobook", "failed", text)
        return "audiobook"

    if "error:" in lower and current_step:
        _set_step_status(run_id, current_step, "failed", text)

    return current_step


def _finalize_step_states(run_id: int, run_status: str, fallback_error: str = "") -> None:
    steps = PipelineStepStatus.objects.filter(pipeline_run_id=run_id)
    for step in steps:
        if run_status == "success":
            if step.status in {"pending", "running"}:
                step.status = "success"
                if not step.detail:
                    step.detail = "Completed successfully"
                step.save(update_fields=["status", "detail", "updated_at"])
        elif run_status == "stopped":
            if step.status == "running":
                step.status = "skipped"
                step.detail = "Stopped by user"
                step.save(update_fields=["status", "detail", "updated_at"])
        elif run_status == "failed":
            if step.status == "running":
                step.status = "failed"
                if fallback_error:
                    step.detail = fallback_error
                step.save(update_fields=["status", "detail", "updated_at"])


def execute_run(run: PipelineRun) -> None:
    run.refresh_from_db()
    profile = run.video_asset.execution_profile
    _ensure_step_rows(run)

    target_step = _next_pending_step_name(run)
    if target_step is None:
        run.status = "success"
        run.finished_at = timezone.now()
        run.exit_code = 0
        run.error_message = ""
        run.pid = None
        run.process_group_id = None
        run.save(update_fields=[
            "status",
            "finished_at",
            "exit_code",
            "error_message",
            "pid",
            "process_group_id",
            "updated_at",
        ])
        return

    try:
        selected_video_path = _resolve_video_path_for_run(run)
        root_dir = Path(settings.WEBAPP["ROOT_DIR"])
    except Exception as exc:
        run.status = "failed"
        run.started_at = timezone.now()
        run.finished_at = timezone.now()
        run.exit_code = 127
        run.pid = None
        run.process_group_id = None
        run.error_message = str(exc)
        run.save(update_fields=[
            "status",
            "started_at",
            "finished_at",
            "exit_code",
            "pid",
            "process_group_id",
            "error_message",
            "updated_at",
        ])
        _finalize_step_states(run.id, "failed", run.error_message)
        return

    log_dir = ensure_webapp_log_dir()
    stamp = timezone.now().strftime("%Y%m%d_%H%M%S")
    log_file = log_dir / f"run-{run.id}-{stamp}.log"

    run.status = "running"
    run.started_at = timezone.now()
    run.log_file_path = str(log_file)
    run.error_message = ""
    run.save(update_fields=["status", "started_at", "log_file_path", "error_message", "updated_at"])

    current_step = None

    with open(log_file, "a", encoding="utf-8") as fh:
        fh.write("[webapp] command: script-based direct pipeline\n")
        fh.write(f"[webapp] run mode: {run.run_mode}\n")
        fh.write(f"[webapp] target step: {target_step}\n")
        fh.write("[webapp] worker kind: serial-cpu\n")
        fh.write(f"[webapp] selected video path: {selected_video_path}\n")
        fh.flush()

        rc, step_error = _execute_pipeline_single_step(
            run=run,
            profile=profile,
            video_path=Path(selected_video_path),
            root_dir=root_dir,
            log_fh=fh,
            target_step=target_step,
        )

        if step_error:
            fh.write(f"[webapp] error: {step_error}\n")
            fh.flush()

    run.exit_code = rc
    run.pid = None
    run.process_group_id = None

    if run.stop_requested:
        run.status = "stopped"
        run.finished_at = timezone.now()
    elif rc == 0:
        run.refresh_from_db()
        next_step = _next_pending_step_name(run)
        if next_step is None:
            run.status = "success"
            run.finished_at = timezone.now()
            run.exit_code = 0
        else:
            run.status = "queued"
            run.finished_at = None
            run.exit_code = None
    else:
        run.status = "failed"
        run.finished_at = timezone.now()
        run.error_message = f"Process failed with code {rc}. See log: {run.log_file_path}"

    run.save(update_fields=[
        "status",
        "exit_code",
        "finished_at",
        "pid",
        "process_group_id",
        "error_message",
        "updated_at",
    ])

    if run.status in {"success", "failed", "stopped"}:
        _finalize_step_states(run.id, run.status, run.error_message)
