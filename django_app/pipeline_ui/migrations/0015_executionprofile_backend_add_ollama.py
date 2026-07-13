from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("pipeline_ui", "0014_executionprofile_backend_add_nllb_hf"),
    ]

    operations = [
        migrations.AlterField(
            model_name="executionprofile",
            name="backend",
            field=models.CharField(
                choices=[
                    ("google", "google"),
                    ("nllb_local", "nllb_local"),
                    ("nllb_hf", "nllb_hf"),
                    ("deepl_doc", "deepl_doc"),
                    ("gemini", "gemini"),
                    ("ollama", "ollama"),
                ],
                default="nllb_local",
                max_length=32,
            ),
        ),
    ]
