"""Customer push notification tokens (FCM) - Customer app Phase C2.

SAFE: sirf CreateModel (1 nayi table). Koi table drop/rename nahi, koi RemoveField nahi,
koi RunSQL/RunPython nahi. Purani tables ko chhua nahi gaya.

Number 0065 is liye ke 0064 (vendor_product_offer) pehle se maujood hai.
"""
import django.db.models.deletion
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('app', '0064_vendor_product_offer'),
    ]

    operations = [
        migrations.CreateModel(
            name='CustomerPushToken',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('token', models.CharField(max_length=255, unique=True)),
                ('device', models.CharField(blank=True, default='', help_text='Phone ka naam/model (optional, sirf pehchan ke liye)', max_length=100)),
                ('platform', models.CharField(default='android', max_length=20)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('customer', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='push_tokens', to='app.customer')),
            ],
            options={
                'ordering': ['-updated_at'],
            },
        ),
    ]
