from django import template
from ..models import CompanyInfo
from ..customer.whatsapp_link import build_whatsapp_link, support_text

register = template.Library()


@register.simple_tag
def wa_support_url(order_no):
    """Order tracking pages ke liye: company ke WhatsApp par order number ke sath pre-written message."""
    if not order_no:
        return ''
    try:
        company = CompanyInfo.objects.only('name', 'contact_number').first()
    except Exception:
        return ''
    return build_whatsapp_link(company, support_text(order_no))
