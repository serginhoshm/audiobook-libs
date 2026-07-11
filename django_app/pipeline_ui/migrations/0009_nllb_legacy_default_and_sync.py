from django.db import migrations, models


def sync_nllb_legacy_flags(apps, schema_editor):
    ExecutionProfile = apps.get_model("pipeline_ui", "ExecutionProfile")

    ExecutionProfile.objects.filter(nllb_profile="legacy").update(nllb_legacy=True)
    ExecutionProfile.objects.filter(nllb_profile__in=["fast", "custom"]).update(nllb_legacy=False)


class Migration(migrations.Migration):

    dependencies = [
        ("pipeline_ui", "0008_executionprofile_remove_libretranslate_backend"),
    ]

    operations = [
        migrations.AlterField(
            model_name="executionprofile",
            name="nllb_profile",
            field=models.CharField(
                choices=[("fast", "fast"), ("legacy", "legacy"), ("custom", "custom")],
                default="legacy",
                max_length=16,
            ),
        ),
        migrations.AlterField(
            model_name="executionprofile",
            name="nllb_legacy",
            field=models.BooleanField(default=True),
        ),
        migrations.RunPython(sync_nllb_legacy_flags, migrations.RunPython.noop),
    ]