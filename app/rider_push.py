"""
Rider app ko PUSH notification (Firebase Cloud Messaging, HTTP v1).

App band ho / screen lock ho, bas phone mein internet (data) on ho - notification aa jati hai.

Setup (ek dafa):
  Firebase Console > Project settings > Service accounts > "Generate new private key"
  Us JSON ko GitHub Secret  FCM_SERVICE_ACCOUNT_JSON  mein paste karein (deploy.yml ise env mein deta hai).
  (Poora JSON text ya uska base64 - dono chalte hain.)

Ye module Django par depend nahi karta (sirf os / requests / google-auth).
Koi bhi ghalti sirf log hoti hai - order ka kaam kabhi nahi rukta.
"""
import base64
import json
import logging
import os
import threading

import requests

logger = logging.getLogger(__name__)

SCOPE = 'https://www.googleapis.com/auth/firebase.messaging'
CHANNEL_ID = 'new_orders'          # rider app isi naam ka high-importance channel banati hai
TTL = '300s'                       # 5 min mein phone na mile to message khatam (purana order kaam ka nahi)
_HTTP_TIMEOUT = 15

_lock = threading.Lock()
_cache = {'info': None, 'creds': None, 'warned': False}


# ---------------------------------------------------------------- config

def _service_account():
    """FCM_SERVICE_ACCOUNT_JSON (JSON ya base64 JSON) -> dict, warna None."""
    if _cache['info'] is not None:
        return _cache['info'] or None
    raw = (os.environ.get('FCM_SERVICE_ACCOUNT_JSON') or '').strip()
    info = {}
    if raw:
        try:
            if not raw.startswith('{'):
                raw = base64.b64decode(raw).decode('utf-8')
            parsed = json.loads(raw)
            if parsed.get('type') == 'service_account' and parsed.get('private_key') and parsed.get('project_id'):
                info = parsed
            else:
                logger.error('FCM_SERVICE_ACCOUNT_JSON service-account key jaisi nahi lagti.')
        except Exception:
            logger.exception('FCM_SERVICE_ACCOUNT_JSON parh nahi saka.')
    _cache['info'] = info
    return info or None


def is_configured():
    ok = _service_account() is not None
    if not ok and not _cache['warned']:
        _cache['warned'] = True
        logger.info('Rider push band hai: FCM_SERVICE_ACCOUNT_JSON set nahi.')
    return ok


def _access_token(force_refresh=False):
    """OAuth2 access token (google-auth se, expire hone par khud refresh)."""
    info = _service_account()
    if not info:
        return None
    try:
        from google.auth.transport.requests import Request
        from google.oauth2 import service_account
    except ImportError:
        logger.error('google-auth install nahi (pip install google-auth) - push nahi ja sakta.')
        return None
    with _lock:
        creds = _cache['creds']
        if creds is None:
            creds = service_account.Credentials.from_service_account_info(info, scopes=[SCOPE])
            _cache['creds'] = creds
        if force_refresh or not creds.valid:
            creds.refresh(Request())
        return creds.token


# ---------------------------------------------------------------- sending

def build_message(token, title, body, data=None, tag=None, channel_id=None, ttl=None):
    """FCM v1 message. 'notification' wala hissa isliye ke app band ho tab bhi system khud dikhaye.

    channel_id / ttl optional hain (Vendor app apne channels aur lambi ttl ke liye use karti hai);
    na dein to rider wala purana behaviour jyon ka tyon."""
    android_note = {
        'channel_id': channel_id or CHANNEL_ID,
        'sound': 'default',
        'notification_priority': 'PRIORITY_MAX',
        'visibility': 'PUBLIC',
    }
    if tag:
        android_note['tag'] = str(tag)
    return {'message': {
        'token': token,
        'notification': {'title': title, 'body': body},
        'data': {str(k): str(v) for k, v in (data or {}).items()},
        'android': {'priority': 'HIGH', 'ttl': ttl or TTL, 'notification': android_note},
    }}


def _is_dead_token(status, payload):
    """True = ye token ab kisi kaam ka nahi (app uninstall / token badal gaya)."""
    err = (payload or {}).get('error') or {}
    codes = {d.get('errorCode') for d in err.get('details', []) if isinstance(d, dict)}
    if status == 404 or 'UNREGISTERED' in codes:
        return True
    return status == 400 and 'registration token' in str(err.get('message', '')).lower()


def _post(url, message, access_token):
    return requests.post(
        url, json=message, timeout=_HTTP_TIMEOUT,
        headers={'Authorization': f'Bearer {access_token}', 'Content-Type': 'application/json; charset=UTF-8'})


def send_to_tokens(tokens, title, body, data=None, tag=None, channel_id=None, ttl=None):
    """Sab tokens ko bhejo (blocking). Return: {'sent': n, 'failed': n, 'dead': [tokens]}."""
    result = {'sent': 0, 'failed': 0, 'dead': []}
    info = _service_account()
    tokens = [t for t in dict.fromkeys(tokens or []) if t]
    if not info or not tokens:
        return result
    try:
        access = _access_token()
    except Exception:
        logger.exception('FCM access token nahi mila.')
        access = None
    if not access:
        result['failed'] = len(tokens)
        return result
    url = f"https://fcm.googleapis.com/v1/projects/{info['project_id']}/messages:send"
    for tok in tokens:
        try:
            msg = build_message(tok, title, body, data, tag, channel_id=channel_id, ttl=ttl)
            r = _post(url, msg, access)
            if r.status_code == 401:                    # token expire ho gaya: ek dafa naya lekar dobara
                access = _access_token(force_refresh=True)
                r = _post(url, msg, access)
            if r.status_code == 200:
                result['sent'] += 1
                continue
            try:
                payload = r.json()
            except ValueError:
                payload = {}
            if _is_dead_token(r.status_code, payload):
                result['dead'].append(tok)
            else:
                result['failed'] += 1
                logger.warning('FCM error %s: %s', r.status_code, str(payload)[:300])
        except Exception:
            result['failed'] += 1
            logger.exception('FCM send failed')
    return result


def push_async(tokens, title, body, data=None, tag=None):
    """Background thread mein bhejo (request / transaction ko na roke). Dead tokens DB se hata do."""
    tokens = list(tokens or [])
    if not tokens or not is_configured():
        return

    def _run():
        try:
            res = send_to_tokens(tokens, title, body, data, tag)
            logger.info('Rider push: sent=%s failed=%s dead=%s', res['sent'], res['failed'], len(res['dead']))
            if res['dead']:
                from django.db import connection
                try:
                    from .models import RiderPushToken
                    RiderPushToken.objects.filter(token__in=res['dead']).delete()
                finally:
                    connection.close()
        except Exception:
            logger.exception('Rider push thread failed')

    threading.Thread(target=_run, name='rider-push', daemon=True).start()
