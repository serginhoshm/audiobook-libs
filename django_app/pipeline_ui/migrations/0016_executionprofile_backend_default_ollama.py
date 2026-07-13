from django.db import migrations, models


def set_all_profiles_to_ollama(apps, schema_editor):
    ExecutionProfile = apps.get_model("pipeline_ui", "ExecutionProfile")
    ExecutionProfile.objects.exclude(backend="ollama").update(backend="ollama")


class Migration(migrations.Migration):

    dependencies = [
        ("pipeline_ui", "0015_executionprofile_backend_add_ollama"),
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
                default="ollama",
                max_length=32,
            ),
        ),
        migrations.RunPython(set_all_profiles_to_ollama, migrations.RunPython.noop),
    ]