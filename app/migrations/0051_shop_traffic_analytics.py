import django.db.models.deletion
from django.db import migrations, models


class Migration(migrations.Migration):
    """Traffic Analytics: sirf 3 NAYE tables. Koi purana table/column touch ya drop nahi hota."""

    dependencies = [
        ('app', '0050_customerotp_reset_purposes'),
    ]

    operations = [
        migrations.CreateModel(
            name='ShopTrafficEvent',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('event_type', models.CharField(choices=[('page', 'Page view'), ('product', 'Product view'), ('cart_add', 'Add to cart')], db_index=True, max_length=10)),
                ('day', models.DateField(db_index=True, help_text='Local (Asia/Karachi) date')),
                ('hour', models.PositiveSmallIntegerField(default=0)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('session_key', models.CharField(blank=True, db_index=True, default='', max_length=100)),
                ('product_name', models.CharField(blank=True, default='', max_length=200)),
                ('quantity', models.PositiveIntegerField(default=1)),
                ('path', models.CharField(blank=True, default='', max_length=255)),
                ('device', models.CharField(blank=True, default='', max_length=10)),
                ('source', models.CharField(blank=True, default='direct', max_length=30)),
                ('product', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='traffic_events', to='app.product')),
            ],
            options={
                'verbose_name': 'Shop Traffic Event',
                'verbose_name_plural': 'Shop Traffic Events',
                'ordering': ['-created_at'],
                'indexes': [
                    models.Index(fields=['event_type', 'day'], name='shoptraf_type_day_idx'),
                    models.Index(fields=['product', 'day'], name='shoptraf_prod_day_idx'),
                ],
            },
        ),
        migrations.CreateModel(
            name='ShopSearchLog',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('keyword', models.CharField(max_length=100)),
                ('keyword_norm', models.CharField(db_index=True, max_length=100)),
                ('results_count', models.PositiveIntegerField(default=0)),
                ('corrected_to', models.CharField(blank=True, default='', max_length=100)),
                ('day', models.DateField(db_index=True)),
                ('hour', models.PositiveSmallIntegerField(default=0)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('session_key', models.CharField(blank=True, default='', max_length=100)),
                ('device', models.CharField(blank=True, default='', max_length=10)),
            ],
            options={
                'verbose_name': 'Shop Search Log',
                'verbose_name_plural': 'Shop Search Logs',
                'ordering': ['-created_at'],
                'indexes': [
                    models.Index(fields=['day', 'keyword_norm'], name='shopsearch_day_kw_idx'),
                ],
            },
        ),
        migrations.CreateModel(
            name='ShopTrafficDaily',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('day', models.DateField(db_index=True)),
                ('kind', models.CharField(choices=[('site', 'Site'), ('product', 'Product'), ('search', 'Search')], max_length=10)),
                ('label', models.CharField(blank=True, default='', max_length=200)),
                ('views', models.PositiveIntegerField(default=0)),
                ('visitors', models.PositiveIntegerField(default=0)),
                ('cart_adds', models.PositiveIntegerField(default=0)),
                ('searches', models.PositiveIntegerField(default=0)),
                ('zero_results', models.PositiveIntegerField(default=0)),
                ('product', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='traffic_daily', to='app.product')),
            ],
            options={
                'verbose_name': 'Shop Traffic Daily Summary',
                'verbose_name_plural': 'Shop Traffic Daily Summaries',
                'ordering': ['-day', 'kind'],
                'indexes': [
                    models.Index(fields=['kind', 'day'], name='shoptraf_daily_kind_idx'),
                ],
            },
        ),
    ]
