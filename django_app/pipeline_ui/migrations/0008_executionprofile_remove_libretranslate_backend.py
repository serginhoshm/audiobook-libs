from django.db import migrations, models


def migrate_libretranslate_backend_to_google(apps, schema_editor):
    ExecutionProfile = apps.get_model("pipeline_ui", "ExecutionProfile")
    ExecutionProfile.objects.filter(backend="libretranslate").update(backend="google")


def noop_reverse(apps, schema_editor):
    return


class Migration(migrations.Migration):

    dependencies = [
        ("pipeline_ui", "0007_remove_executionprofile_cuda_fields"),
    ]

    operations = [
        migrations.RunPython(migrate_libretranslate_backend_to_google, noop_reverse),
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
