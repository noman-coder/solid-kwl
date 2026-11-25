"""flutter create ke baad AndroidManifest.xml mein zaroori permissions + app name lagata hai.
Usage: python3 tool/patch_manifest.py android/app/src/main/AndroidManifest.xml "App Name"
(App ka naam workflow ke APP_NAME se aata hai - ek hi jagah se badalta hai.)
"""
import re
import sys
from xml.sax.saxutils import quoteattr

path = sys.argv[1]
app_name = sys.argv[2] if len(sys.argv) > 2 else 'Vendor App'
s = open(path, encoding='utf-8').read()

# Vendor ko GPS / background location nahi chahiye (woh rider app ka kaam hai).
PERMS = [
    'android.permission.INTERNET',
    'android.permission.POST_NOTIFICATIONS',
    'android.permission.WAKE_LOCK',
    'android.permission.VIBRATE',
    # Phase V7: 'Battery unrestricted' ki ijazat (permissions_help screen) - naye order ka alert band na ho
    'android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS',
]
add = ''.join(f'    <uses-permission android:name="{p}"/>\n' for p in PERMS if p not in s)

INTENTS = '''        <intent><action android:name="android.intent.action.VIEW"/><data android:scheme="https"/></intent>
        <intent><action android:name="android.intent.action.DIAL"/><data android:scheme="tel"/></intent>
'''
if '<queries>' in s:
    if 'android.intent.action.DIAL' not in s:
        s = s.replace('<queries>', '<queries>\n' + INTENTS, 1)
else:
    add += '    <queries>\n' + INTENTS + '    </queries>\n'

if add:
    s = s.replace('<application', add + '    <application', 1)

# Push notification: FCM ka default channel (server vendor_push.py 'new_orders' / 'updates' channel par bhejta hai)
META = '<meta-data android:name="com.google.firebase.messaging.default_notification_channel_id" android:value="new_orders"/>'
if 'default_notification_channel_id' not in s:
    s = s.replace('</application>', '        ' + META + '\n    </application>', 1)

# app ka naam (phone par icon ke neeche)
s = re.sub(r'android:label="[^"]*"', 'android:label=' + quoteattr(app_name), s, count=1)

open(path, 'w', encoding='utf-8').write(s)
print('manifest patched')
