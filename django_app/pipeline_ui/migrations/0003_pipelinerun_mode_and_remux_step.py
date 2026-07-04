from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("pipeline_ui", "0002_executionprofile_defaults_and_remove_normalize"),
    ]

    operations = [
        migrations.AddField(
            model_name="pipelinerun",
            name="run_mode",
            field=models.CharField(
                choices=[("pipeline", "pipeline"), ("remux", "remux")],
                default="pipeline",
                max_length=24,
            ),
        ),
        migrations.AlterField(
            model_name="pipelinestepstatus",
            name="step_name",
            field=models.CharField(
                choices=[
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
