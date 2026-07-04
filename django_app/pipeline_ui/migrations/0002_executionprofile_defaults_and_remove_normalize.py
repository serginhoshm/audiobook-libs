from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("pipeline_ui", "0001_initial"),
    ]

    operations = [
        migrations.AlterField(
            model_name="executionprofile",
            name="backend",
            field=models.CharField(
                choices=[
                    ("google", "google"),
                    ("nllb_local", "nllb_local"),
                    ("deepl_doc", "deepl_doc"),
                    ("gemini", "gemini"),
                ],
                default="deepl_doc",
                max_length=32,
            ),
        ),
        migrations.AlterField(
            model_name="executionprofile",
            name="cuda_enabled",
            field=models.BooleanField(default=True),
        ),
        migrations.RemoveField(
            model_name="executionprofile",
            name="normalize_dry_run",
        ),
    ]
