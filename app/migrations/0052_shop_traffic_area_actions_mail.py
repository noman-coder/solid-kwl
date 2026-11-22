import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):
    """Traffic Analytics v2: sirf naya kaam. Naya column apne hi (naye) traffic table mein, 2 naye tables.
    Koi purana table/column change ya drop nahi hota."""

    dependencies = [
        ('app', '0051_shop_traffic_analytics'),
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]

    operations = [
        migrations.AddField(
            model_name='shoptrafficevent',
            name='area',
            field=models.CharField(blank=True, default='', help_text='Customer ka "Deliver to" shehar/area', max_length=100),
        ),
        migrations.AlterField(
            model_name='shoptrafficdaily',
            name='kind',
            field=models.CharField(choices=[('site', 'Site'), ('product', 'Product'), ('search', 'Search'), ('area', 'Area')], max_length=10),
        ),
        migrations.CreateModel(
            name='ShopKeywordAction',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('keyword_norm', models.CharField(max_length=100, unique=True)),
                ('action', models.CharField(choices=[('alias', 'Alias added'), ('ignored', 'Ignored')], max_length=10)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('created_by', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to=settings.AUTH_USER_MODEL)),
                ('product', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to='app.product')),
            ],
            options={
                'verbose_name': 'Shop Keyword Action',
                'verbose_name_plural': 'Shop Keyword Actions',
                'ordering': ['-created_at'],
            },
        ),
        migrations.CreateModel(
            name='ShopTrafficMailLog',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('day', models.DateField(help_text='Jis din ki summary hai', unique=True)),
                ('sent_at', models.DateTimeField(auto_now_add=True)),
                ('recipients', models.CharField(blank=True, default='', max_length=500)),
            ],
            options={
                'verbose_name': 'Shop Traffic Mail Log',
                'verbose_name_plural': 'Shop Traffic Mail Logs',
                'ordering': ['-day'],
            },
        ),
    ]
