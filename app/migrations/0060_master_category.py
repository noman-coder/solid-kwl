"""Master categories (shop home par bari categories) - SAFE.

Sirf: 1 nayi table (MasterCategory) + Category mein 2 nullable columns (master, master_source) +
8 default master rows. Koi table drop/rename nahi, koi RemoveField nahi. Purani categories jyon ki tyon;
unhein master dene ke liye baad mein chalayein:  python manage.py classify_categories
"""
import django.db.models.deletion
from django.db import migrations, models

SEED = [
    ('Food & Drinks', '🍽️', 1), ('Grocery', '🛒', 2), ('Health & Beauty', '💄', 3),
    ('Baby & Kids', '🧸', 4), ('Home & Cleaning', '🏠', 5), ('Electronics', '📱', 6),
    ('Fashion', '👕', 7), ('Other', '🛍️', 99),
]


def seed(apps, schema_editor):
    M = apps.get_model('app', 'MasterCategory')
    for name, icon, order in SEED:
        M.objects.get_or_create(name=name, defaults={'icon': icon, 'sort_order': order})


class Migration(migrations.Migration):

    dependencies = [
        ('app', '0059_rider_push_token'),
    ]

    operations = [
        migrations.CreateModel(
            name='MasterCategory',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('name', models.CharField(max_length=60, unique=True)),
                ('icon', models.CharField(blank=True, default='🛍️', help_text='Ek emoji, jaise 🍽️ 🛒 💊', max_length=8)),
                ('sort_order', models.PositiveSmallIntegerField(default=0, help_text='Chhota number pehle nazar aata hai')),
                ('is_active', models.BooleanField(default=True)),
            ],
            options={
                'verbose_name': 'Master Category',
                'verbose_name_plural': '1.2a Master Categories',
                'ordering': ['sort_order', 'name'],
            },
        ),
        migrations.AddField(
            model_name='category',
            name='master',
            field=models.ForeignKey(blank=True, help_text='Shop par ye category kis bari category ke andar dikhe. Khali chhorein to AI khud chun legi.', null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='categories', to='app.mastercategory'),
        ),
        migrations.AddField(
            model_name='category',
            name='master_source',
            field=models.CharField(blank=True, default='', help_text='Master kis ne chuna: keyword / ai / fallback (check karein) / manual (admin ne)', max_length=10),
        ),
        migrations.RunPython(seed, migrations.RunPython.noop),
    ]
