"""Store location verification (blue tick) + customer location.

SAFE: sirf AddField hain. Koi table drop/wipe/rename nahi, koi RunPython/RunSQL nahi.
Purani rows mein naye columns NULL / False rehte hain.
"""
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('app', '0053_shop_traffic_v3'),
    ]

    operations = [
        migrations.AddField(
            model_name='vendorprofile', name='latitude',
            field=models.FloatField(blank=True, null=True, help_text='Store ki verified latitude'),
        ),
        migrations.AddField(
            model_name='vendorprofile', name='longitude',
            field=models.FloatField(blank=True, null=True, help_text='Store ki verified longitude'),
        ),
        migrations.AddField(
            model_name='vendorprofile', name='location_accuracy_m',
            field=models.FloatField(blank=True, null=True, help_text='GPS accuracy (meters) jab location li gayi'),
        ),
        migrations.AddField(
            model_name='vendorprofile', name='location_consent_at',
            field=models.DateTimeField(blank=True, null=True, help_text='Vendor ne privacy page par kab ittefaq kiya'),
        ),
        migrations.AddField(
            model_name='vendorprofile', name='location_verified',
            field=models.BooleanField(default=False, verbose_name='Location verified',
                                      help_text='True = store naam ke saath blue tick nazar aata hai'),
        ),
        migrations.AddField(
            model_name='vendorprofile', name='location_verified_at',
            field=models.DateTimeField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name='customerprofile', name='latitude',
            field=models.FloatField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name='customerprofile', name='longitude',
            field=models.FloatField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name='customerprofile', name='location_updated_at',
            field=models.DateTimeField(blank=True, null=True),
        ),
    ]
