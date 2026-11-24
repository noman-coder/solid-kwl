"""Rider push notification tokens (FCM).

SAFE: sirf CreateModel (1 nayi table). Koi table drop/rename nahi, koi RemoveField nahi,
koi RunSQL/RunPython nahi. Purani tables ko chhua nahi gaya.
"""
import django.db.models.deletion
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('app', '0058_rider_cash_handover'),
    ]

    operations = [
        migrations.CreateModel(
            name='RiderPushToken',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('token', models.CharField(max_length=255, unique=True)),
                ('platform', models.CharField(default='android', max_length=20)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('rider', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='push_tokens', to='app.riderprofile')),
            ],
            options={
                'ordering': ['-updated_at'],
            },
        ),
    ]
