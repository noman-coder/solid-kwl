"""Coupons, Favorite Stores, vendor reply on reviews.

SAFE: sirf naye tables (CreateModel) aur naye columns (AddField, default ke saath).
Koi table drop / column remove / rename nahi, koi RunPython/RunSQL nahi - purana data jyon ka tyon rehta hai.
"""
from decimal import Decimal

from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
        ('app', '0055_shop_wishlist'),
    ]

    operations = [
        # ---- naye columns (purani rows par default lagta hai) ----
        migrations.AddField(
            model_name='saleorder',
            name='coupon_code',
            field=models.CharField(blank=True, default='', max_length=30),
        ),
        migrations.AddField(
            model_name='orderreview',
            name='vendor_reply',
            field=models.CharField(blank=True, default='', max_length=300),
        ),
        migrations.AddField(
            model_name='orderreview',
            name='vendor_replied_at',
            field=models.DateTimeField(blank=True, null=True),
        ),
        # ---- naye tables ----
        migrations.CreateModel(
            name='Coupon',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('code', models.CharField(help_text='Capital letters / numbers, jaise WELCOME50', max_length=30, unique=True)),
                ('title', models.CharField(blank=True, default='', help_text="Customer ko dikhne wali line, jaise 'Pehle order par 20% off'", max_length=80)),
                ('discount_type', models.CharField(choices=[('percent', 'Percent (%) discount'), ('fixed', 'Fixed amount (Rs.) discount'), ('free_delivery', 'Free delivery')], default='percent', max_length=20)),
                ('value', models.DecimalField(decimal_places=2, default=Decimal('0.00'), help_text='Percent ya Rs. (Free delivery mein zaroorat nahi)', max_digits=10)),
                ('max_discount', models.DecimalField(blank=True, decimal_places=2, help_text='Percent coupon par discount ki hadd (Rs.)', max_digits=10, null=True)),
                ('min_order', models.DecimalField(decimal_places=2, default=Decimal('0.00'), help_text='Items ka kam az kam total (delivery ke baghair)', max_digits=10)),
                ('usage_limit', models.PositiveIntegerField(blank=True, help_text='Kul kitni dafa chal sakta hai (khali = be-had)', null=True)),
                ('per_customer_limit', models.PositiveSmallIntegerField(default=1, help_text='Ek customer kitni dafa (0 = be-had)')),
                ('first_order_only', models.BooleanField(default=False, help_text='Sirf naye customer ke pehle order par')),
                ('valid_from', models.DateTimeField(blank=True, null=True)),
                ('valid_until', models.DateTimeField(blank=True, null=True)),
                ('is_active', models.BooleanField(default=True)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('created_by', models.ForeignKey(blank=True, editable=False, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='created_coupons', to=settings.AUTH_USER_MODEL)),
                ('vendor', models.ForeignKey(blank=True, help_text='Khali = poori shop ke liye. Bhara = sirf us store ke cart par.', null=True, on_delete=django.db.models.deletion.CASCADE, related_name='coupons', to='app.vendor')),
            ],
            options={
                'verbose_name': 'Coupon',
                'verbose_name_plural': '3.4 Coupons',
                'ordering': ['-created_at'],
            },
        ),
        migrations.CreateModel(
            name='CouponRedemption',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('discount_amount', models.DecimalField(decimal_places=2, default=Decimal('0.00'), max_digits=12)),
                ('delivery_waived', models.DecimalField(decimal_places=2, default=Decimal('0.00'), max_digits=10)),
                ('funded_by', models.CharField(default='shop', max_length=10)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('coupon', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='redemptions', to='app.coupon')),
                ('customer', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='coupon_redemptions', to='app.customer')),
                ('sale_order', models.OneToOneField(on_delete=django.db.models.deletion.CASCADE, related_name='coupon_redemption', to='app.saleorder')),
            ],
            options={
                'verbose_name': 'Coupon Redemption',
                'verbose_name_plural': '3.5 Coupon Redemptions',
                'ordering': ['-created_at'],
            },
        ),
        migrations.AddIndex(
            model_name='coupon',
            index=models.Index(fields=['vendor', 'is_active'], name='app_coupon_vendor_active_idx'),
        ),
        migrations.CreateModel(
            name='FavoriteStore',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('customer', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='favorite_stores', to='app.customer')),
                ('store', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='favorited_by', to='app.vendorprofile')),
            ],
            options={
                'verbose_name': 'Favorite Store',
                'verbose_name_plural': 'Favorite Stores',
                'ordering': ['-created_at'],
                'unique_together': {('customer', 'store')},
            },
        ),
    ]
