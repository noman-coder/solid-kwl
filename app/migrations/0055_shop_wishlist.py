"""Customer Favorites (wishlist).

SAFE: sirf naya table (CreateModel). Koi table drop/wipe/rename nahi, koi RunPython/RunSQL nahi.
"""
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        ('app', '0054_location_verification'),
    ]

    operations = [
        migrations.CreateModel(
            name='ShopWishlist',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('customer', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE,
                                               related_name='wishlist_items', to='app.customer')),
                ('product', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE,
                                              related_name='wishlisted_by', to='app.product')),
            ],
            options={
                'verbose_name': 'Shop Favorite',
                'verbose_name_plural': 'Shop Favorites',
                'ordering': ['-created_at'],
                'unique_together': {('customer', 'product')},
            },
        ),
    ]
