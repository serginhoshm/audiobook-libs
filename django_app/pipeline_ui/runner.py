import os
import select
import signal
import subprocess
import time
from pathlib import Path
from typing import Any

from django.conf import settings
from django.utils import timezone

from .models import ExecutionProfile, PipelineRun, PipelineStepStatus
from .services import load_work_exec_dir


STEP_ORDER = ["extract", "transcribe", "translate", "audiobook"]


def _bool_to_on_off(value: bool) -> str:
    return "on" if value else "off"


def _display_lang_tag(lang: str) -> str:
    if lang == "es":
        return "spanish"
    if lang == "zh-CN":
        return "chinese"
    return "auto"


def _ordered_video_paths() -> list[str]:
    work_exec = load_work_exec_dir()
    videos = []
    for path in sorted(work_exec.iterdir()):
        if path.is_file() and path.suffix.lower() in {".mp4", ".mkv"}:
            name = path.name.lower()
            if "spanish" in name:
                lang = "es"
            elif "chinese" in name:
                lang = "zh-CN"
            else:
                lang = "auto"
            videos.append((str(path), lang))

    ordered = []
    for group in ["spanish", "chinese", "auto"]:
        for file_path, lang in videos:
            if _display_lang_tag(lang) == group:
                ordered.append(file_path)
    return ordered


def _selection_index_for_video(video_path: str) -> int:
    ordered = _ordered_video_paths()
    for idx, path in enumerate(ordered, start=1):
        if path == video_path:
            return idx
    raise ValueError(f"Video nao encontrado no indice do exec.sh: {video_path}")


def build_exec_command(profile: ExecutionProfile) -> list[str]:
    root_dir = Path(settings.WEBAPP["ROOT_DIR"])
    command = ["bash", str(root_dir / "workflows" / "exec.sh")]

    command.extend(["--backend", profile.backend])
    command.extend(["--nllb-profile", profile.nllb_profile])
    command.extend(["--nllb-max-input-length", str(profile.nllb_max_input_length)])
    command.extend(["--nllb-max-new-tokens", str(profile.nllb_max_new_tokens)])
    command.extend(["--nllb-gpu", _bool_to_on_off(profile.nllb_gpu)])

    if profile.nllb_legacy:
        command.append("--nllb-legacy")
    else:
        command.append("--no-nllb-legacy")

    command.extend(["--deepl-endpoint", profile.deepl_endpoint])

    if profile.reset_deepl_keys_state:
        command.append("--reset-deepl-keys-state")

    command.extend(["--whisper-cuda", _bool_to_on_off(profile.cuda_enabled)])
    command.extend(["--piper-cuda", _bool_to_on_off(profile.cuda_enabled)])

    return command


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
    for step_name in STEP_ORDER:
        PipelineStepStatus.objects.get_or_create(
            pipeline_run=run,
            step_name=step_name,
            defaults={"status": "pending", "detail": ""},
        )


def _set_step_status(run_id: int, step_name: str, status: str, detail: str = "") -> None:
    PipelineStepStatus.objects.filter(pipeline_run_id=run_id, step_name=step_name).update(
        status=status,
        detail=detail,
        updated_at=timezone.now(),
    )


def _promote_step_from_log_line(run_id: int, line: str, current_step: str | None) -> str | None:
    text = line.strip()
    lower = text.lower()

    if "etapa 0 - extracao" in lower:
        _set_step_status(run_id, "extract", "running", text)
        return "extract"
    if "etapa 1 - transcricao" in lower:
        _set_step_status(run_id, "transcribe", "running", text)
        return "transcribe"
    if "etapa 2 - traducao" in lower:
        _set_step_status(run_id, "translate", "running", text)
        return "translate"
    if "etapa 3" in lower or "geracao wav (piper)" in lower or "sintese" in lower:
        _set_step_status(run_id, "audiobook", "running", text)
        return "audiobook"

    if "srt traduzido nao gerado/validado" in lower:
        _set_step_status(run_id, "translate", "failed", text)
        return "translate"

    if "wav/pt.wav nao gerado/validado" in lower or "audio" in lower and "nao gerado/validado" in lower:
        _set_step_status(run_id, "audiobook", "failed", text)
        return "audiobook"

    if "erro:" in lower and current_step:
        _set_step_status(run_id, current_step, "failed", text)

    return current_step


def _finalize_step_states(run_id: int, run_status: str, fallback_error: str = "") -> None:
    steps = PipelineStepStatus.objects.filter(pipeline_run_id=run_id)
    for step in steps:
        if run_status == "success":
            if step.status in {"pending", "running"}:
                step.status = "success"
                if not step.detail:
                    step.detail = "Concluido com sucesso"
                step.save(update_fields=["status", "detail", "updated_at"])
        elif run_status == "stopped":
            if step.status == "running":
                step.status = "skipped"
                step.detail = "Interrompido pelo usuario"
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

    command = build_exec_command(profile)
    selection_index = _selection_index_for_video(run.video_asset.file_path)

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
        fh.write(f"[webapp] command: {' '.join(command)}\n")
        fh.write(f"[webapp] selection index: {selection_index}\n")
        fh.flush()

        proc = subprocess.Popen(
            command,
            cwd=str(settings.WEBAPP["ROOT_DIR"]),
            stdin=subprocess.PIPE,
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

        if proc.stdin:
            proc.stdin.write(f"{selection_index}\n")
            proc.stdin.flush()
            proc.stdin.close()

        grace = int(settings.WEBAPP["WORKER_GRACE_SECONDS"])

        stdout_stream = proc.stdout

        while True:
            if stdout_stream:
                ready, _, _ = select.select([stdout_stream], [], [], 0.8)
                if ready:
                    line = stdout_stream.readline()
                    if line:
                        fh.write(line)
                        fh.flush()
                        current_step = _promote_step_from_log_line(run.id, line, current_step)

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
                fh.write(line)
                fh.flush()
                current_step = _promote_step_from_log_line(run.id, line, current_step)

    run.exit_code = rc
    run.finished_at = timezone.now()
    run.pid = None
    run.process_group_id = None

    if run.stop_requested:
        run.status = "stopped"
    elif rc == 0:
        run.status = "success"
    else:
        run.status = "failed"
        run.error_message = f"Processo finalizou com codigo {rc}. Veja log: {run.log_file_path}"

    run.save(update_fields=[
        "status",
        "exit_code",
        "finished_at",
        "pid",
        "process_group_id",
        "error_message",
        "updated_at",
    ])

    _finalize_step_states(run.id, run.status, run.error_message)
