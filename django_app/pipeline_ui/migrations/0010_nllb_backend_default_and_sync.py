from django.db import migrations, models


def sync_legacy_profiles_to_nllb_local(apps, schema_editor):
    ExecutionProfile = apps.get_model("pipeline_ui", "ExecutionProfile")

    ExecutionProfile.objects.filter(
        nllb_profile="legacy",
        nllb_legacy=True,
    ).update(backend="nllb_local")


class Migration(migrations.Migration):

    dependencies = [
        ("pipeline_ui", "0009_nllb_legacy_default_and_sync"),
    ]

    operations = [
        migrations.AlterField(
            model_name="executionprofile",
            name="backend",
            field=models.CharField(
                choices=[("google", "google"), ("nllb_local", "nllb_local"), ("deepl_doc", "deepl_doc"), ("gemini", "gemini")],
                default="nllb_local",
                max_length=32,
            ),
        ),
        migrations.RunPython(sync_legacy_profiles_to_nllb_local, migrations.RunPython.noop),
    ]