"""Rider cash handover (COD cash admin / vendor ko dena, receiver confirm).

SAFE: sirf CreateModel (1 nayi table + M2M table). Koi table drop/rename nahi, koi RemoveField nahi,
koi RunSQL/RunPython nahi. Purani tables ko chhua nahi gaya.
"""
import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('app', '0057_rider_live_location'),
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]

    operations = [
        migrations.CreateModel(
            name='RiderCashHandover',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('receiver', models.CharField(choices=[('admin', 'Admin'), ('vendor', 'Vendor')], max_length=10)),
                ('amount', models.DecimalField(decimal_places=2, max_digits=12)),
                ('note', models.CharField(blank=True, default='', max_length=200)),
                ('status', models.CharField(choices=[('pending', 'Pending'), ('confirmed', 'Confirmed'), ('rejected', 'Rejected')], default='pending', max_length=10)),
                ('reject_reason', models.CharField(blank=True, default='', max_length=200)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('decided_at', models.DateTimeField(blank=True, null=True)),
                ('decided_by', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to=settings.AUTH_USER_MODEL)),
                ('orders', models.ManyToManyField(blank=True, help_text='Kin orders ka cash (optional)', related_name='cash_handovers', to='app.deliveryinfo')),
                ('rider', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='handovers', to='app.riderprofile')),
                ('settlement', models.OneToOneField(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='handover', to='app.ridersettlement')),
                ('vendor', models.ForeignKey(blank=True, help_text="receiver == 'vendor' par zaroori", null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='rider_cash_handovers', to='app.vendor')),
            ],
            options={
                'ordering': ['-created_at'],
                'indexes': [
                    models.Index(fields=['rider', 'status'], name='app_rch_rider_status_idx'),
                    models.Index(fields=['receiver', 'vendor', 'status'], name='app_rch_recv_vendor_idx'),
                ],
            },
        ),
    ]
