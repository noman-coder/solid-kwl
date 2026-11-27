"""
Category -> Master category (shop home ki bari categories) khud chunna.

Tarteeb (sasta/tez pehle):
  1. KEYWORDS  - cake/juice/sabzi/atta... jaise lafz mil jayein to foran, bina API ke.
  2. GEMINI    - keyword na mile to Gemini se poochte hain. Sirf maujooda master list mein se chunta hai
                 (naya master kabhi nahi banata), jawab DB mein save ho jata hai, dobara nahi poochte.
  3. FALLBACK  - API band / key nahi / ghalat jawab -> "Other" aur master_source='fallback'
                 (admin list mein filter kar ke dekh leta hai).
Admin jo master khud chune (master_source='manual') use AI kabhi nahi badalti.

Settings / env:  GEMINI_API_KEY (zaroori, sirf server par), GEMINI_MODEL (default gemini-2.5-flash),
                 CATEGORY_AI_AUTO=1 (default; 0 = nayi category par khud-bakhud AI band)
"""
import json
import logging
import re

import requests
from django.conf import settings
from django.core.cache import cache

logger = logging.getLogger(__name__)

OTHER = 'Other'

# Tarteeb ahmiyat rakhti hai: pehle wali master jeetti hai ("baby milk" -> Baby, "hair oil" -> Beauty).
KEYWORDS = [
    ('Baby & Kids', ['baby', 'diaper', 'kids', 'toy', 'toys', 'infant', 'feeder', 'pampers']),
    ('Health & Beauty', ['medicine', 'pharmacy', 'health', 'tablet', 'syrup', 'vitamin', 'beauty', 'cosmetic',
                         'makeup', 'skin', 'hair', 'soap', 'shampoo', 'personal care', 'lotion', 'perfume', 'face cream']),
    ('Electronics', ['mobile', 'phone', 'electronic', 'electronics', 'charger', 'cable', 'computer', 'laptop',
                     'headphone', 'earbuds', 'camera', 'speaker', 'battery', 'tv']),
    ('Fashion', ['cloth', 'clothes', 'shirt', 'dress', 'shoe', 'shoes', 'garment', 'fashion', 'wear', 'jeans',
                 'bag', 'watch', 'jewellery', 'jewelry', 'kapray', 'suit']),
    ('Home & Cleaning', ['clean', 'cleaning', 'detergent', 'wash', 'washing', 'household', 'home', 'kitchen',
                         'furniture', 'tissue', 'bulb', 'stationery', 'tool', 'tools', 'hardware']),
    ('Grocery', ['grocery', 'atta', 'flour', 'daal', 'dal', 'pulses', 'oil', 'ghee', 'spice', 'spices', 'masala',
                 'sugar', 'salt', 'rice', 'chawal', 'cooking', 'staples']),
    ('Food & Drinks', ['food', 'cake', 'cakes', 'bakery', 'bread', 'biscuit', 'cookie', 'fruit', 'fruits', 'juice',
                       'drink', 'drinks', 'beverage', 'beverages', 'coffee', 'tea', 'chai', 'sabzi', 'vegetable',
                       'vegetables', 'meat', 'chicken', 'beef', 'mutton', 'gosht', 'fish', 'seafood', 'egg',
                       'eggs', 'anda', 'dairy', 'milk', 'doodh', 'yogurt', 'dahi', 'butter', 'cheese', 'sweet',
                       'sweets', 'mithai', 'chocolate', 'dessert', 'candy', 'ice cream', 'snack', 'snacks',
                       'chips', 'namkeen', 'nimko', 'biryani', 'burger', 'pizza', 'fast food', 'sandwich',
                       'shawarma', 'roll', 'water', 'cola', 'soda', 'frozen', 'pulao', 'bbq', 'karahi']),
]


def _tokens(name):
    return [t for t in re.split(r'[^a-z0-9]+', (name or '').lower()) if t]


def keyword_master(name):
    """Naam se master ka naam, ya None agar koi keyword na mile."""
    low = (name or '').lower()
    toks = _tokens(name)
    for master, words in KEYWORDS:
        for w in words:
            if ' ' in w:
                if w in low:
                    return master
            elif w in toks:
                return master
    return None


def _ai_enabled():
    return bool(getattr(settings, 'GEMINI_API_KEY', ''))


def gemini_master(name, master_names):
    """Gemini se poochho. master_names mein se ek naam, ya None (ghalat jawab/error/timeout)."""
    key = getattr(settings, 'GEMINI_API_KEY', '')
    if not key or not master_names:
        return None
    model = getattr(settings, 'GEMINI_MODEL', 'gemini-2.5-flash')
    prompt = (
        "You sort product categories of a Pakistani online shop into ONE master category.\n"
        f"Master categories: {json.dumps(master_names, ensure_ascii=False)}\n"
        "Category names may be English, Urdu or Roman Urdu (e.g. sabzi=vegetables, doodh=milk, mithai=sweets, "
        "kapray=clothes). Pick the single best master from the list. If none fits, answer \"Other\". "
        "Never invent a new master.\n"
        f"Category name: {json.dumps(name, ensure_ascii=False)}"
    )
    body = {
        'contents': [{'parts': [{'text': prompt}]}],
        'generationConfig': {
            'temperature': 0,
            'responseMimeType': 'application/json',
            'responseSchema': {
                'type': 'OBJECT',
                'properties': {'master': {'type': 'STRING', 'enum': list(master_names)}},
                'required': ['master'],
            },
        },
    }
    try:
        r = requests.post(
            f'https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent',
            headers={'x-goog-api-key': key, 'Content-Type': 'application/json'},
            json=body, timeout=10)
        r.raise_for_status()
        text = r.json()['candidates'][0]['content']['parts'][0]['text']
        answer = (json.loads(text).get('master') or '').strip()
    except Exception as exc:   # network, quota, parse - category add kabhi nahi rukni chahiye
        logger.warning('Gemini category classify failed for %r: %s', name, exc)
        return None
    return answer if answer in master_names else None


def classify(name, master_names=None, use_ai=True):
    """(master_name, source). source: keyword / ai / fallback."""
    hit = keyword_master(name)
    if hit:
        return hit, 'keyword'
    if use_ai and _ai_enabled():
        names = master_names or []
        ans = gemini_master(name, names)
        if ans:
            return ans, 'ai'
    return OTHER, 'fallback'


def clear_shop_category_cache():
    cache.delete_many(['shop_home_categories', 'shop_home_masters', 'all_categories'])


def assign_master(category, force=False, use_ai=True):
    """Category ko master do aur save karo. Manual choice ko haath nahi lagate (force=True ho to lagate hain).
    Return: (master_name, source) ya None agar kuch nahi badla."""
    from .models import Category, MasterCategory
    category = Category.objects.get(pk=category.pk)
    if not force and category.master_id:
        return None                      # pehle se master hai (manual ya AI) - na chhedein
    masters = {m.name: m for m in MasterCategory.objects.filter(is_active=True)}
    if not masters:
        return None
    name, source = classify(category.name, list(masters), use_ai=use_ai)
    master = masters.get(name) or masters.get(OTHER)
    if master is None:
        return None
    Category.objects.filter(pk=category.pk).update(master=master, master_source=source)
    clear_shop_category_cache()
    return master.name, source
