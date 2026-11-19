"""WhatsApp (wa.me) link helpers — koi model/DB change nahi, sirf CompanyInfo.contact_number use hota hai."""
import re
from urllib.parse import quote


def whatsapp_number(company):
    """Company ke contact number ko international digits mein badalta hai (Pakistan: 03xx -> 923xx).
    Number na ho ya ghalat ho to '' return karta hai."""
    raw = (getattr(company, 'contact_number', '') or '').strip()
    digits = re.sub(r'\D', '', raw)
    if not digits:
        return ''
    if digits.startswith('00'):
        digits = digits[2:]
    if digits.startswith('0'):
        digits = '92' + digits[1:]
    elif len(digits) == 10 and digits.startswith('3'):
        digits = '92' + digits
    return digits if len(digits) >= 10 else ''


def build_whatsapp_link(company, text=None):
    """wa.me link pre-written message ke sath. text na do to shop ka default message lagta hai."""
    digits = whatsapp_number(company)
    if not digits:
        return ''
    if text is None:
        name = getattr(company, 'name', '') or 'your shop'
        text = (f"Assalam o Alaikum! Mujhe {name} ki shop se products ke baare mein "
                f"maloomat chahiye. Please meri madad karein.")
    return f"https://wa.me/{digits}?text={quote(text)}"


def _rs(value):
    try:
        from decimal import Decimal, ROUND_HALF_UP
        return f"{Decimal(str(value)).quantize(Decimal('1'), rounding=ROUND_HALF_UP):,}"
    except Exception:
        return str(value)


def product_order_text(name, price, qty, url):
    total = float(price) * int(qty)
    return (f"Assalam o Alaikum! Mujhe ye product order karna hai:\n\n"
            f"Product: {name}\nQuantity: {qty}\nPrice: Rs. {_rs(price)} (per unit)\n"
            f"Total: Rs. {_rs(total)}\nLink: {url}\n\nPlease confirm karein.")


def cart_order_text(cart_items, subtotal, delivery_charges, total_amount):
    lines = []
    for i, it in enumerate(cart_items, 1):
        lines.append(f"{i}. {it.get('name')} x {it.get('quantity')} = Rs. {_rs(it.get('subtotal', 0))}")
    text = "Assalam o Alaikum! Mujhe ye order karna hai:\n\n" + "\n".join(lines)
    text += f"\n\nSubtotal: Rs. {_rs(subtotal)}"
    if delivery_charges:
        text += f"\nDelivery: Rs. {_rs(delivery_charges)}"
    text += f"\nTotal: Rs. {_rs(total_amount)}\n\nPlease order confirm karein."
    return text


def support_text(order_no):
    return (f"Assalam o Alaikum! Mujhe apne order #{order_no} ke baare mein madad chahiye. "
            f"Please iska status bata dein.")
