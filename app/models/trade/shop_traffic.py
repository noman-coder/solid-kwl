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
    ORDER = 'order'
    BANNER = 'banner'
    NOTFOUND = 'notfound'
    EVENT_TYPES = [
        (PAGE, 'Page view'),
        (PRODUCT, 'Product view'),
        (CART, 'Add to cart'),
        (ORDER, 'Order placed'),
        (BANNER, 'Banner click'),
        (NOTFOUND, 'Page not found (404)'),
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
    area = models.CharField(max_length=100, blank=True, default='', help_text='Customer ka "Deliver to" shehar/area')
    visitor_id = models.CharField(max_length=36, blank=True, default='', db_index=True)
    user_id = models.PositiveIntegerField(null=True, blank=True, help_text='Login customer ka user id')
    ref_id = models.PositiveIntegerField(null=True, blank=True, help_text='Order / banner id')
    label = models.CharField(max_length=255, blank=True, default='', help_text='Banner naam ya 404 ka referrer')
    amount = models.DecimalField(max_digits=12, decimal_places=2, default=0)

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
    AREA = 'area'
    KINDS = [(SITE, 'Site'), (PRODUCT, 'Product'), (SEARCH, 'Search'), (AREA, 'Area')]

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


class ShopKeywordAction(models.Model):
    """Admin ne "Not Found" keyword ka kya kiya: alias laga diya ya ignore kar diya."""
    ALIAS = 'alias'
    IGNORED = 'ignored'
    ACTIONS = [(ALIAS, 'Alias added'), (IGNORED, 'Ignored')]

    keyword_norm = models.CharField(max_length=100, unique=True)
    action = models.CharField(max_length=10, choices=ACTIONS)
    product = models.ForeignKey(
        'Product', null=True, blank=True, on_delete=models.SET_NULL, related_name='+')
    created_by = models.ForeignKey(
        'auth.User', null=True, blank=True, on_delete=models.SET_NULL, related_name='+')
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        verbose_name = 'Shop Keyword Action'
        verbose_name_plural = 'Shop Keyword Actions'
        ordering = ['-created_at']

    def __str__(self):
        return f"{self.keyword_norm} -> {self.action}"


class ShopTrafficMailLog(models.Model):
    """Daily summary email: har din ki sirf aik entry, taake email do baar na jaye."""
    day = models.DateField(unique=True, help_text='Jis din ki summary hai')
    sent_at = models.DateTimeField(auto_now_add=True)
    recipients = models.CharField(max_length=500, blank=True, default='')

    class Meta:
        verbose_name = 'Shop Traffic Mail Log'
        verbose_name_plural = 'Shop Traffic Mail Logs'
        ordering = ['-day']

    def __str__(self):
        return f"{self.day} sent {self.sent_at:%H:%M}"


class ShopVisitor(models.Model):
    """Har browser ka aik record (cookie se): naya vs wapas aane wala visitor pehchanne ke liye. Kabhi delete nahi hota."""
    visitor_id = models.CharField(max_length=36, unique=True)
    first_seen = models.DateField(db_index=True)
    last_seen = models.DateField()
    visits = models.PositiveIntegerField(default=1, help_text='Kitne alag dinon mein aaya')

    class Meta:
        verbose_name = 'Shop Visitor'
        verbose_name_plural = 'Shop Visitors'

    def __str__(self):
        return f"{self.visitor_id[:8]} ({self.visits})"


class ShopCartFollowup(models.Model):
    """Abandoned cart par kis ne follow-up kiya (cart_key = session ka hash, asal session key nahi)."""
    cart_key = models.CharField(max_length=40, unique=True)
    contacted_by = models.ForeignKey(
        'auth.User', null=True, blank=True, on_delete=models.SET_NULL, related_name='+')
    contacted_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        verbose_name = 'Shop Cart Follow-up'
        verbose_name_plural = 'Shop Cart Follow-ups'
        ordering = ['-contacted_at']

    def __str__(self):
        return f"{self.cart_key[:8]} @ {self.contacted_at:%d %b %H:%M}"


class ShopHiddenItem(models.Model):
    """Dashboard list se chhupai gayi cheezein (jaise theek ho chuka 404 link)."""
    kind = models.CharField(max_length=10)
    key = models.CharField(max_length=255)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        verbose_name = 'Shop Hidden Item'
        verbose_name_plural = 'Shop Hidden Items'
        unique_together = ('kind', 'key')

    def __str__(self):
        return f"{self.kind}: {self.key}"
