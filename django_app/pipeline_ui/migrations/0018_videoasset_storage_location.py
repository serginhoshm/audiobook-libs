from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("pipeline_ui", "0017_alter_videoasset_file_path_remove_unique"),
    ]

    operations = [
        migrations.AddField(
            model_name="videoasset",
            name="storage_location",
            field=models.CharField(choices=[("exec", "exec"), ("library", "library")], default="exec", max_length=16),
        ),
    ]