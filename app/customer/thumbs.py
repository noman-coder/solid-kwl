"""
Phase V17: list wali screens ke liye chhoti (thumbnail) tasveer.

App ki lists (products / offers) mein poori bari photo mangwane se data aur memory zaya hoti hai. Yahan se chhoti JPEG milti hai
(`media/thumbs/<size>/...`). Asli photo kabhi nahi badalti. Sirf local file storage par; Cloudinary jaisi storage par ya
koi bhi masla ho to asli photo ka link hi wapas aata hai (kabhi crash nahi).
"""
import hashlib
import logging
import os

from django.conf import settings

logger = logging.getLogger(__name__)

THUMB_SIZE = 360          # pixel (lambi taraf)
THUMB_QUALITY = 78


def thumb_url(field, size=THUMB_SIZE):
    """ImageField -> chhoti photo ka link (na ho sake to asli ka link, photo na ho to None)."""
    if not field:
        return None
    try:
        original = field.url
    except ValueError:
        return None
    try:
        src = field.path                       # cloud storage par NotImplementedError -> asli link
        if not os.path.isfile(src):
            return original
        key = hashlib.sha1(field.name.encode('utf-8')).hexdigest()[:20]
        rel = f'thumbs/{size}/{key}.jpg'
        dst = os.path.join(settings.MEDIA_ROOT, *rel.split('/'))
        if not (os.path.isfile(dst) and os.path.getmtime(dst) >= os.path.getmtime(src)):
            from PIL import Image, ImageOps
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            with Image.open(src) as im:
                im = ImageOps.exif_transpose(im)
                if im.mode not in ('RGB', 'L'):
                    bg = Image.new('RGB', im.size, (255, 255, 255))
                    im = im.convert('RGBA')
                    bg.paste(im, mask=im.split()[-1])
                    im = bg
                else:
                    im = im.convert('RGB')
                im.thumbnail((size, size))
                tmp = dst + '.tmp'
                im.save(tmp, 'JPEG', quality=THUMB_QUALITY, optimize=True)
            os.replace(tmp, dst)
        return settings.MEDIA_URL.rstrip('/') + '/' + rel
    except Exception:                         # NotImplementedError, kharab photo, permission ... - asli link chalega
        logger.debug('thumb fallback for %s', getattr(field, 'name', ''), exc_info=True)
        return original
