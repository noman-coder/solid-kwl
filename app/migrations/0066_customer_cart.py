"""Customer app ka server-side cart (CustomerCart) - Customer app Phase C7.

SAFE: sirf CreateModel (1 nayi table). Koi table drop/rename nahi, koi RemoveField nahi,
koi RunSQL/RunPython nahi. Purani tables ko chhua nahi gaya.
"""
import django.db.models.deletion
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('app', '0065_customer_push_token'),
    ]

    operations = [
        migrations.CreateModel(
            name='CustomerCart',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('items', models.JSONField(blank=True, default=dict)),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('customer', models.OneToOneField(on_delete=django.db.models.deletion.CASCADE, related_name='app_cart', to='app.customer')),
            ],
            options={
                'ordering': ['-updated_at'],
            },
        ),
    ]
