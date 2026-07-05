from django.db import migrations


class Migration(migrations.Migration):

    dependencies = [
        ("pipeline_ui", "0004_executionprofile_backend_default_google"),
    ]

    operations = [
        migrations.RemoveField(
            model_name="executionprofile",
            name="reset_deepl_keys_state",
        ),
    ]