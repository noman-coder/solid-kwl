"""Models: trade/shop_wishlist - customer ki Favorites (pasandida products).

Naya table; purane data ko koi asar nahi.
"""
from django.db import models


class ShopWishlist(models.Model):
    customer = models.ForeignKey(
        'Customer', on_delete=models.CASCADE, related_name='wishlist_items')
    product = models.ForeignKey(
        'Product', on_delete=models.CASCADE, related_name='wishlisted_by')
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        unique_together = ('customer', 'product')
        ordering = ['-created_at']
        verbose_name = 'Shop Favorite'
        verbose_name_plural = 'Shop Favorites'

    def __str__(self):
        return f"{self.customer_id} -> {self.product_id}"
