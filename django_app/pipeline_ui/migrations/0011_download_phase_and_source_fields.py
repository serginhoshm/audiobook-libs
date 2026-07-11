from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("pipeline_ui", "0010_nllb_backend_default_and_sync"),
    ]

    operations = [
        migrations.AddField(
            model_name="videoasset",
            name="source_duration_seconds",
            field=models.FloatField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name="videoasset",
            name="source_url",
            field=models.CharField(blank=True, default="", max_length=2048),
        ),
        migrations.AlterField(
            model_name="pipelinestepstatus",
            name="step_name",
            field=models.CharField(
                choices=[
                    ("download", "download"),
                    ("extract", "extract"),
                    ("transcribe", "transcribe"),
                    ("translate", "translate"),
                    ("audiobook", "audiobook"),
                    ("remux", "remux"),
                ],
                max_length=24,
            ),
        ),
    ]
