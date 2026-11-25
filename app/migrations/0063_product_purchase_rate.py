"""Product purchase rate - Vendor app Phase V11 (profit hisaab).

SAFE: sirf AddField (1 nayi nullable column). Koi table/column drop/rename nahi, koi RunSQL/RunPython nahi.
Purani rows ka purchase_rate NULL rehta hai (app mein profit 'N/A').
"""
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('app', '0062_vendor_stock_log'),
    ]

    operations = [
        migrations.AddField(
            model_name='product',
            name='purchase_rate',
            field=models.DecimalField(
                blank=True, decimal_places=2, max_digits=10, null=True,
                help_text='Vendor ka kharid rate (sirf profit hisaab ke liye; customer ko nahi dikhta)',
                verbose_name='Purchase Rate'),
        ),
    ]
