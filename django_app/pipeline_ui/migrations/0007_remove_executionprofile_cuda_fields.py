from django.db import migrations


class Migration(migrations.Migration):

    dependencies = [
        ("pipeline_ui", "0006_executionprofile_backend_default_libretranslate"),
    ]

    operations = [
        migrations.RemoveField(
            model_name="executionprofile",
            name="cuda_enabled",
        ),
        migrations.RemoveField(
            model_name="executionprofile",
            name="nllb_gpu",
        ),
    ]