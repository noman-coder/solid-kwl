"""Vendor product offers - Vendor app Phase V13-B.

SAFE: sirf CreateModel (1 nayi table). Koi table/column drop/rename nahi, koi RunSQL/RunPython nahi.
Product ki price / discount_percentage / original_price ko chhua nahi gaya.
"""
import django.db.models.deletion
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('app', '0063_product_purchase_rate'),
    ]

    operations = [
        migrations.CreateModel(
            name='ProductOffer',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('discount_percent', models.DecimalField(decimal_places=2, max_digits=5)),
                ('starts_at', models.DateTimeField()),
                ('ends_at', models.DateTimeField(help_text='Is waqt se pehle tak chalta hai (ends_at khud shamil nahi)')),
                ('is_active', models.BooleanField(default=True, help_text='Vendor ka chalu / band switch')),
                ('request_key', models.CharField(blank=True, db_index=True, default='', max_length=64)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('product', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='vendor_offers', to='app.product')),
                ('profile', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='product_offers', to='app.vendorprofile')),
            ],
            options={
                'ordering': ['-created_at', '-id'],
            },
        ),
        migrations.AddIndex(
            model_name='productoffer',
            index=models.Index(fields=['product', 'is_active', 'starts_at', 'ends_at'], name='poffer_prod_window'),
        ),
        migrations.AddIndex(
            model_name='productoffer',
            index=models.Index(fields=['profile', '-created_at'], name='poffer_profile_created'),
        ),
    ]
