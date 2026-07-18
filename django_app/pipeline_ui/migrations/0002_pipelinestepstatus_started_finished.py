from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("pipeline_ui", "0001_initial"),
    ]

    operations = [
        migrations.AddField(
            model_name="pipelinestepstatus",
            name="started_at",
            field=models.DateTimeField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name="pipelinestepstatus",
            name="finished_at",
            field=models.DateTimeField(blank=True, null=True),
        ),
    ]
