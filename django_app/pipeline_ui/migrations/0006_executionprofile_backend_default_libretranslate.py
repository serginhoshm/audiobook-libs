from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("pipeline_ui", "0005_remove_executionprofile_reset_deepl_keys_state"),
    ]

    operations = [
        migrations.AlterField(
            model_name="executionprofile",
            name="backend",
            field=models.CharField(
                choices=[
                    ("libretranslate", "libretranslate"),
                    ("google", "google"),
                    ("nllb_local", "nllb_local"),
                    ("deepl_doc", "deepl_doc"),
                    ("gemini", "gemini"),
                ],
                default="libretranslate",
                max_length=32,
            ),
        ),
    ]