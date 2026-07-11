import json
from pathlib import Path

from django.http import HttpRequest, HttpResponse, JsonResponse
from django.shortcuts import render
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_GET, require_http_methods, require_POST

from .models import PipelineRun

from .services import (
    list_assets,
    queue_download_job,
    queue_runs,
    request_stop_for_runs,
    run_evidence_worker,
    scan_videos,
    update_execution_profile,
    worker_health_status,
)


def _json_payload(request: HttpRequest) -> dict:
    try:
        if not request.body:
            return {}
        return json.loads(request.body.decode("utf-8"))
    except Exception:
        return {}


def _json_error(message: str, status: int = 400) -> JsonResponse:
    return JsonResponse({"ok": False, "error": message}, status=status)


def index(request: HttpRequest) -> HttpResponse:
    return render(request, "pipeline_ui/index.html", {})


@require_GET
def api_videos(request: HttpRequest) -> JsonResponse:
    present_only = request.GET.get("present_only", "true").lower() != "false"
    return JsonResponse({"items": list_assets(present_only=present_only)})


@csrf_exempt
@require_POST
def api_scan(request: HttpRequest) -> JsonResponse:
    summary = scan_videos()
    evidence = run_evidence_worker(include_housekeeping=True)
    return JsonResponse({"ok": True, "summary": summary, "evidence": evidence})


@csrf_exempt
@require_POST
def api_runs_start(request: HttpRequest) -> JsonResponse:
    payload = _json_payload(request)
    video_ids = payload.get("video_ids") or []
    if not isinstance(video_ids, list) or not video_ids:
        return JsonResponse({"ok": False, "error": "video_ids is empty"}, status=400)

    result = queue_runs([int(v) for v in video_ids])
    return JsonResponse({"ok": True, "result": result})


@csrf_exempt
@require_POST
def api_download_add(request: HttpRequest) -> JsonResponse:
    payload = _json_payload(request)
    source_url = str(payload.get("source_url") or "").strip()
    if not source_url:
        return _json_error("source_url is empty", status=400)

    try:
        result = queue_download_job(source_url)
    except ValueError as exc:
        return _json_error(str(exc), status=400)
    except Exception as exc:
        return _json_error(str(exc), status=500)

    return JsonResponse({"ok": True, "result": result})


@csrf_exempt
@require_POST
def api_runs_stop(request: HttpRequest) -> JsonResponse:
    payload = _json_payload(request)
    run_ids = payload.get("run_ids") or []
    video_ids = payload.get("video_ids") or []

    count = request_stop_for_runs(
        run_ids=[int(v) for v in run_ids] if run_ids else None,
        video_ids=[int(v) for v in video_ids] if video_ids else None,
    )
    return JsonResponse({"ok": True, "requested_stop": count})


@require_GET
def api_status(request: HttpRequest) -> JsonResponse:
    include_log_tail = request.GET.get("include_log_tail", "false").lower() in {"1", "true", "yes", "on"}
    return JsonResponse(
        {
            "ok": True,
            "items": list_assets(
                present_only=True,
                include_active_runs=True,
                include_log_tail=include_log_tail,
            ),
        }
    )


@require_GET
def api_run_log(request: HttpRequest, run_id: int) -> HttpResponse:
    run = PipelineRun.objects.filter(id=run_id).first()
    if run is None:
        return HttpResponse("Run not found\n", status=404, content_type="text/plain; charset=utf-8")

    log_file_path = run.log_file_path
    if not log_file_path:
        return HttpResponse("Log is unavailable for this run\n", status=404, content_type="text/plain; charset=utf-8")

    path = Path(log_file_path)
    if not path.exists() or (not path.is_file()):
        return HttpResponse("Log file not found\n", status=404, content_type="text/plain; charset=utf-8")

    text = path.read_text(encoding="utf-8", errors="replace")
    return HttpResponse(text, content_type="text/plain; charset=utf-8")


@require_GET
def api_worker_status(request: HttpRequest) -> JsonResponse:
    return JsonResponse({"ok": True, "worker": worker_health_status()})


@csrf_exempt
@require_http_methods(["PATCH", "POST"])
def api_video_options_patch(request: HttpRequest, video_id: int) -> JsonResponse:
    payload = _json_payload(request)
    profile = update_execution_profile(video_id, payload)
    return JsonResponse(
        {
            "ok": True,
            "video_id": video_id,
            "profile": {
                "backend": profile.backend,
                "nllb_profile": profile.nllb_profile,
                "nllb_max_input_length": profile.nllb_max_input_length,
                "nllb_max_new_tokens": profile.nllb_max_new_tokens,
                "nllb_legacy": profile.nllb_legacy,
                "deepl_endpoint": profile.deepl_endpoint,
            },
        }
    )
