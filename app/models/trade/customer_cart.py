"""Customer app ka server-side cart - Customer app Phase C7.

Web ka cart session mein rehta hai; app stateless (token) hai, is liye cart ek nayi table mein.
Additive only: ek nayi table. Koi purani table/column change nahi hota.

`items` ka format web session cart jaisa hi hai ({"<product_id>": {product_id, name, price, quantity, image, vendor_id}}),
taake calculate_cart_data / store_orders.cart_store_rules / (Phase C8) place_order seedha usi ko le sakein.
Ek customer = ek cart (OneToOne).
"""
from django.db import models


class CustomerCart(models.Model):
    customer = models.OneToOneField('Customer', on_delete=models.CASCADE, related_name='app_cart')
    items = models.JSONField(default=dict, blank=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['-updated_at']

    def __str__(self):
        return f"Cart: {self.customer.name} ({len(self.items or {})} items)"
