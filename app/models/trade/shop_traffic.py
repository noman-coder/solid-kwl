"""Shop traffic analytics (admin "Traffic Analytics" dashboard).

Sirf NAYE tables hain: koi purana table/column change ya drop nahi hota.
  - ShopTrafficEvent : har page view / product view / add-to-cart ka record (raw, 90 din)
  - ShopSearchLog    : har search keyword (chahe product mila ho ya nahi)
  - ShopTrafficDaily : 90 din se purana raw data yahan daily summary ban kar hamesha rehta hai
Product delete ho to analytics rows delete nahi hoti (SET_NULL + naam ka snapshot).
"""
from django.db import models


class ShopTrafficEvent(models.Model):
    PAGE = 'page'
    PRODUCT = 'product'
    CART = 'cart_add'
    EVENT_TYPES = [
        (PAGE, 'Page view'),
        (PRODUCT, 'Product view'),
        (CART, 'Add to cart'),
    ]

    event_type = models.CharField(max_length=10, choices=EVENT_TYPES, db_index=True)
    day = models.DateField(db_index=True, help_text='Local (Asia/Karachi) date')
    hour = models.PositiveSmallIntegerField(default=0)
    created_at = models.DateTimeField(auto_now_add=True)
    session_key = models.CharField(max_length=100, blank=True, default='', db_index=True)
    product = models.ForeignKey(
        'Product', null=True, blank=True, on_delete=models.SET_NULL, related_name='traffic_events')
    product_name = models.CharField(max_length=200, blank=True, default='')
    quantity = models.PositiveIntegerField(default=1)
    path = models.CharField(max_length=255, blank=True, default='')
    device = models.CharField(max_length=10, blank=True, default='')
    source = models.CharField(max_length=30, blank=True, default='direct')

    class Meta:
        verbose_name = 'Shop Traffic Event'
        verbose_name_plural = 'Shop Traffic Events'
        ordering = ['-created_at']
        indexes = [
            models.Index(fields=['event_type', 'day'], name='shoptraf_type_day_idx'),
            models.Index(fields=['product', 'day'], name='shoptraf_prod_day_idx'),
        ]

    def __str__(self):
        return f"{self.event_type} {self.day} {self.product_name or self.path}"


class ShopSearchLog(models.Model):
    keyword = models.CharField(max_length=100)
    keyword_norm = models.CharField(max_length=100, db_index=True)
    results_count = models.PositiveIntegerField(default=0)
    corrected_to = models.CharField(max_length=100, blank=True, default='')
    day = models.DateField(db_index=True)
    hour = models.PositiveSmallIntegerField(default=0)
    created_at = models.DateTimeField(auto_now_add=True)
    session_key = models.CharField(max_length=100, blank=True, default='')
    device = models.CharField(max_length=10, blank=True, default='')

    class Meta:
        verbose_name = 'Shop Search Log'
        verbose_name_plural = 'Shop Search Logs'
        ordering = ['-created_at']
        indexes = [models.Index(fields=['day', 'keyword_norm'], name='shopsearch_day_kw_idx')]

    def __str__(self):
        return f"{self.keyword} ({self.results_count})"


class ShopTrafficDaily(models.Model):
    """Daily summary kept forever (raw rows are removed after 90 days, never this)."""
    SITE = 'site'
    PRODUCT = 'product'
    SEARCH = 'search'
    KINDS = [(SITE, 'Site'), (PRODUCT, 'Product'), (SEARCH, 'Search')]

    day = models.DateField(db_index=True)
    kind = models.CharField(max_length=10, choices=KINDS)
    label = models.CharField(max_length=200, blank=True, default='')
    product = models.ForeignKey(
        'Product', null=True, blank=True, on_delete=models.SET_NULL, related_name='traffic_daily')
    views = models.PositiveIntegerField(default=0)
    visitors = models.PositiveIntegerField(default=0)
    cart_adds = models.PositiveIntegerField(default=0)
    searches = models.PositiveIntegerField(default=0)
    zero_results = models.PositiveIntegerField(default=0)

    class Meta:
        verbose_name = 'Shop Traffic Daily Summary'
        verbose_name_plural = 'Shop Traffic Daily Summaries'
        ordering = ['-day', 'kind']
        indexes = [models.Index(fields=['kind', 'day'], name='shoptraf_daily_kind_idx')]

    def __str__(self):
        return f"{self.day} {self.kind} {self.label}"
