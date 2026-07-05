from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("pipeline_ui", "0003_pipelinerun_mode_and_remux_step"),
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
                default="google",
                max_length=32,
            ),
        ),
    ]