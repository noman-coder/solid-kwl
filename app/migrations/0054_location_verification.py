"""Store location verification (blue tick) + customer location.

SAFE: AddField operations only. No table is dropped, wiped or renamed, and there is no RunPython/RunSQL.
Existing rows keep NULL / False in the new columns.
"""
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('app', '0053_shop_traffic_v3'),
    ]

    operations = [
        migrations.AddField(
            model_name='vendorprofile', name='latitude',
            field=models.FloatField(blank=True, null=True, help_text='Verified store latitude'),
        ),
        migrations.AddField(
            model_name='vendorprofile', name='longitude',
            field=models.FloatField(blank=True, null=True, help_text='Verified store longitude'),
        ),
        migrations.AddField(
            model_name='vendorprofile', name='location_accuracy_m',
            field=models.FloatField(blank=True, null=True, help_text='GPS accuracy (meters) when the location was taken'),
        ),
        migrations.AddField(
            model_name='vendorprofile', name='location_consent_at',
            field=models.DateTimeField(blank=True, null=True, help_text='When the vendor agreed on the privacy page'),
        ),
        migrations.AddField(
            model_name='vendorprofile', name='location_verified',
            field=models.BooleanField(default=False, verbose_name='Location verified',
                                      help_text='True = blue tick shown after the store name'),
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
