"""Rider live location (order live tracking).

SAFE: sirf CreateModel (2 nayi tables). Koi table drop/rename nahi, koi RemoveField nahi,
koi RunSQL/RunPython nahi. Purani tables ko chhua nahi gaya.
"""
import django.db.models.deletion
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('app', '0056_coupons_favorites_review_reply'),
    ]

    operations = [
        migrations.CreateModel(
            name='RiderLiveLocation',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('latitude', models.FloatField()),
                ('longitude', models.FloatField()),
                ('accuracy_m', models.FloatField(blank=True, null=True)),
                ('speed_mps', models.FloatField(blank=True, null=True)),
                ('heading', models.FloatField(blank=True, null=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('rider', models.OneToOneField(on_delete=django.db.models.deletion.CASCADE, related_name='live_location', to='app.riderprofile')),
            ],
        ),
        migrations.CreateModel(
            name='RiderLocationLog',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('latitude', models.FloatField()),
                ('longitude', models.FloatField()),
                ('accuracy_m', models.FloatField(blank=True, null=True)),
                ('recorded_at', models.DateTimeField(auto_now_add=True)),
                ('delivery', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='location_logs', to='app.deliveryinfo')),
            ],
            options={
                'ordering': ['-recorded_at'],
                'indexes': [models.Index(fields=['delivery', '-recorded_at'], name='app_rll_deliv_rec_idx')],
            },
        ),
    ]
