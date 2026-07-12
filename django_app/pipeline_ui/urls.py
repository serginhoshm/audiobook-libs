from django.urls import path

from . import views

urlpatterns = [
    path("", views.index, name="index"),
    path("api/videos", views.api_videos, name="api_videos"),
    path("api/worker-status", views.api_worker_status, name="api_worker_status"),
    path("api/runs/<int:run_id>/log", views.api_run_log, name="api_run_log"),
    path("api/scan", views.api_scan, name="api_scan"),
    path("api/runs/start", views.api_runs_start, name="api_runs_start"),
    path("api/downloads/add", views.api_download_add, name="api_download_add"),
    path("api/videos/delete", views.api_videos_delete, name="api_videos_delete"),
    path("api/runs/stop", views.api_runs_stop, name="api_runs_stop"),
    path("api/status", views.api_status, name="api_status"),
    path("api/videos/<int:video_id>/options", views.api_video_options_patch, name="api_video_options_patch"),
]
