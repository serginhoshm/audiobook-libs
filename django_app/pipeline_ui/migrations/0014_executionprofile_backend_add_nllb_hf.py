from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("pipeline_ui", "0013_videoasset_thumbnail_path"),
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
                ],
                default="nllb_local",
                max_length=32,
            ),
        ),
    ]
