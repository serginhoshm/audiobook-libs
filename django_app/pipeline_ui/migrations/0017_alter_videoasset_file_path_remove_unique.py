from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("pipeline_ui", "0016_executionprofile_backend_default_ollama"),
    ]

    operations = [
        migrations.AlterField(
            model_name="videoasset",
            name="file_path",
            field=models.CharField(max_length=1024),
        ),
    ]
