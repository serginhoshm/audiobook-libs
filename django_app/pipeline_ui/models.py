from django.db import models
from django.utils import timezone


class VideoAsset(models.Model):
    file_path = models.CharField(max_length=1024, unique=True)
    file_name = models.CharField(max_length=255)
    source_url = models.CharField(max_length=2048, blank=True, default="")
    youtube_title_original = models.CharField(max_length=255, blank=True, default="")
    youtube_title_pt_br = models.TextField(blank=True, default="")
    thumbnail_path = models.CharField(max_length=1024, blank=True, default="")
    extension = models.CharField(max_length=16, blank=True)
    size_bytes = models.BigIntegerField(default=0)
    duration_seconds = models.FloatField(null=True, blank=True)
    source_duration_seconds = models.FloatField(null=True, blank=True)
    original_language = models.CharField(max_length=24, default="auto")
    discovered_at = models.DateTimeField(default=timezone.now)
    last_seen_at = models.DateTimeField(default=timezone.now)
    is_present = models.BooleanField(default=True)
    is_deleted = models.BooleanField(default=False)

    def __str__(self):
        return self.file_name


class ExecutionProfile(models.Model):
    BACKEND_CHOICES = [
        # ("libretranslate", "libretranslate"),  # Legacy option kept commented for possible reactivation.
        ("google", "google"),
        ("nllb_local", "nllb_local"),
        ("nllb_hf", "nllb_hf"),
        ("deepl_doc", "deepl_doc"),
        ("gemini", "gemini"),
        ("ollama", "ollama"),
    ]

    NLLB_PROFILE_CHOICES = [
        ("fast", "fast"),
        ("legacy", "legacy"),
        ("custom", "custom"),
    ]

    video_asset = models.OneToOneField(VideoAsset, on_delete=models.CASCADE, related_name="execution_profile")
    backend = models.CharField(max_length=32, choices=BACKEND_CHOICES, default="ollama")
    nllb_profile = models.CharField(max_length=16, choices=NLLB_PROFILE_CHOICES, default="legacy")
    nllb_max_input_length = models.PositiveIntegerField(default=768)
    nllb_max_new_tokens = models.PositiveIntegerField(default=192)
    nllb_legacy = models.BooleanField(default=True)
    deepl_endpoint = models.CharField(max_length=64, default="free")
    updated_at = models.DateTimeField(auto_now=True)

    def __str__(self):
        return f"Profile<{self.video_asset_id}>"


class PipelineRun(models.Model):
    RUN_MODE_CHOICES = [
        ("pipeline", "pipeline"),
        ("remux", "remux"),
    ]

    STATUS_CHOICES = [
        ("discovered", "discovered"),
        ("queued", "queued"),
        ("running", "running"),
        ("stopping", "stopping"),
        ("stopped", "stopped"),
        ("success", "success"),
        ("failed", "failed"),
        ("skipped", "skipped"),
    ]

    video_asset = models.ForeignKey(VideoAsset, on_delete=models.CASCADE, related_name="runs")
    run_mode = models.CharField(max_length=24, choices=RUN_MODE_CHOICES, default="pipeline")
    status = models.CharField(max_length=24, choices=STATUS_CHOICES, default="queued")
    started_at = models.DateTimeField(null=True, blank=True)
    finished_at = models.DateTimeField(null=True, blank=True)
    exit_code = models.IntegerField(null=True, blank=True)
    error_message = models.TextField(blank=True)
    log_file_path = models.CharField(max_length=1024, blank=True)
    pid = models.IntegerField(null=True, blank=True)
    process_group_id = models.IntegerField(null=True, blank=True)
    stop_requested = models.BooleanField(default=False)
    created_at = models.DateTimeField(default=timezone.now)
    updated_at = models.DateTimeField(auto_now=True)

    def __str__(self):
        return f"Run<{self.id}:{self.video_asset_id}:{self.status}>"


class PipelineStepStatus(models.Model):
    STEP_CHOICES = [
        ("download", "download"),
        ("extract", "extract"),
        ("transcribe", "transcribe"),
        ("translate", "translate"),
        ("audiobook", "audiobook"),
        ("remux", "remux"),
    ]

    STATUS_CHOICES = [
        ("pending", "pending"),
        ("running", "running"),
        ("success", "success"),
        ("failed", "failed"),
        ("skipped", "skipped"),
    ]

    pipeline_run = models.ForeignKey(PipelineRun, on_delete=models.CASCADE, related_name="steps")
    step_name = models.CharField(max_length=24, choices=STEP_CHOICES)
    status = models.CharField(max_length=24, choices=STATUS_CHOICES, default="pending")
    detail = models.TextField(blank=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        unique_together = ("pipeline_run", "step_name")

    def __str__(self):
        return f"Step<{self.pipeline_run_id}:{self.step_name}:{self.status}>"
