import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):
    """Traffic Analytics v3: apne hi traffic table mein naye columns + 3 naye tables.
    Koi purana table/column change ya drop nahi hota."""

    dependencies = [
        ('app', '0052_shop_traffic_area_actions_mail'),
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]

    operations = [
        migrations.AddField(
            model_name='shoptrafficevent', name='visitor_id',
            field=models.CharField(blank=True, db_index=True, default='', max_length=36),
        ),
        migrations.AddField(
            model_name='shoptrafficevent', name='user_id',
            field=models.PositiveIntegerField(blank=True, help_text='Login customer ka user id', null=True),
        ),
        migrations.AddField(
            model_name='shoptrafficevent', name='ref_id',
            field=models.PositiveIntegerField(blank=True, help_text='Order / banner id', null=True),
        ),
        migrations.AddField(
            model_name='shoptrafficevent', name='label',
            field=models.CharField(blank=True, default='', help_text='Banner naam ya 404 ka referrer', max_length=255),
        ),
        migrations.AddField(
            model_name='shoptrafficevent', name='amount',
            field=models.DecimalField(decimal_places=2, default=0, max_digits=12),
        ),
        migrations.AlterField(
            model_name='shoptrafficevent', name='event_type',
            field=models.CharField(choices=[('page', 'Page view'), ('product', 'Product view'), ('cart_add', 'Add to cart'), ('order', 'Order placed'), ('banner', 'Banner click'), ('notfound', 'Page not found (404)')], db_index=True, max_length=10),
        ),
        migrations.CreateModel(
            name='ShopVisitor',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('visitor_id', models.CharField(max_length=36, unique=True)),
                ('first_seen', models.DateField(db_index=True)),
                ('last_seen', models.DateField()),
                ('visits', models.PositiveIntegerField(default=1, help_text='Kitne alag dinon mein aaya')),
            ],
            options={'verbose_name': 'Shop Visitor', 'verbose_name_plural': 'Shop Visitors'},
        ),
        migrations.CreateModel(
            name='ShopCartFollowup',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('cart_key', models.CharField(max_length=40, unique=True)),
                ('contacted_at', models.DateTimeField(auto_now_add=True)),
                ('contacted_by', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to=settings.AUTH_USER_MODEL)),
            ],
            options={'verbose_name': 'Shop Cart Follow-up', 'verbose_name_plural': 'Shop Cart Follow-ups', 'ordering': ['-contacted_at']},
        ),
        migrations.CreateModel(
            name='ShopHiddenItem',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('kind', models.CharField(max_length=10)),
                ('key', models.CharField(max_length=255)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
            ],
            options={'verbose_name': 'Shop Hidden Item', 'verbose_name_plural': 'Shop Hidden Items', 'unique_together': {('kind', 'key')}},
        ),
    ]
