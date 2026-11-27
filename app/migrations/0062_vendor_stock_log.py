"""Vendor stock history - Vendor app Phase V10.

SAFE: sirf CreateModel (1 nayi table). Koi table drop/rename nahi, koi RemoveField nahi,
koi RunSQL/RunPython nahi. Purani tables ko chhua nahi gaya.
"""
import django.db.models.deletion
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('app', '0061_vendor_push_token'),
    ]

    operations = [
        migrations.CreateModel(
            name='VendorStockLog',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('kind', models.CharField(choices=[('add', 'Stock add'), ('minus', 'Stock kam')], max_length=5)),
                ('qty', models.FloatField()),
                ('before', models.FloatField()),
                ('after', models.FloatField()),
                ('reason', models.CharField(default='other', max_length=20)),
                ('note', models.CharField(blank=True, default='', max_length=200)),
                ('source', models.CharField(default='app', help_text='app | quick_update', max_length=20)),
                ('request_key', models.CharField(blank=True, db_index=True, default='', max_length=64)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('product', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='vendor_stock_logs', to='app.product')),
                ('profile', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='stock_logs', to='app.vendorprofile')),
            ],
            options={
                'ordering': ['-created_at', '-id'],
            },
        ),
        migrations.AddIndex(
            model_name='vendorstocklog',
            index=models.Index(fields=['profile', '-created_at'], name='vstocklog_profile_created'),
        ),
    ]
