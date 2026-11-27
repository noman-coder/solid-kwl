"""Models: trade/favorite_stores - customer ke pasandida stores (naya table, purana data safe)."""
from django.db import models


class FavoriteStore(models.Model):
    customer = models.ForeignKey('Customer', on_delete=models.CASCADE, related_name='favorite_stores')
    store = models.ForeignKey('VendorProfile', on_delete=models.CASCADE, related_name='favorited_by')
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        unique_together = ('customer', 'store')
        ordering = ['-created_at']
        verbose_name = 'Favorite Store'
        verbose_name_plural = 'Favorite Stores'

    def __str__(self):
        return f"{self.customer_id} -> store {self.store_id}"
