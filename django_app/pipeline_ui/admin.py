from django.contrib import admin

from .models import ExecutionProfile, PipelineRun, PipelineStepStatus, VideoAsset


@admin.register(VideoAsset)
class VideoAssetAdmin(admin.ModelAdmin):
    list_display = ("id", "file_name", "original_language", "duration_seconds", "is_present", "last_seen_at")
    search_fields = ("file_name", "file_path")
    list_filter = ("is_present", "original_language")


@admin.register(ExecutionProfile)
class ExecutionProfileAdmin(admin.ModelAdmin):
    list_display = ("id", "video_asset", "backend", "cuda_enabled", "updated_at")
    list_filter = ("backend", "cuda_enabled")


@admin.register(PipelineRun)
class PipelineRunAdmin(admin.ModelAdmin):
    list_display = ("id", "video_asset", "status", "started_at", "finished_at", "exit_code")
    list_filter = ("status",)


@admin.register(PipelineStepStatus)
class PipelineStepStatusAdmin(admin.ModelAdmin):
    list_display = ("id", "pipeline_run", "step_name", "status", "updated_at")
    list_filter = ("step_name", "status")
