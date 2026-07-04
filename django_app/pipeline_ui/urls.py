from django.urls import path

from . import views

urlpatterns = [
    path("", views.index, name="index"),
    path("api/videos", views.api_videos, name="api_videos"),
    path("api/scan", views.api_scan, name="api_scan"),
    path("api/runs/start", views.api_runs_start, name="api_runs_start"),
    path("api/runs/remux/start", views.api_runs_remux_start, name="api_runs_remux_start"),
    path("api/runs/stop", views.api_runs_stop, name="api_runs_stop"),
    path("api/status", views.api_status, name="api_status"),
    path("api/videos/<int:video_id>/options", views.api_video_options_patch, name="api_video_options_patch"),
]
