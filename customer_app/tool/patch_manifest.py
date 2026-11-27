"""flutter create ke baad AndroidManifest.xml mein zaroori permissions + app name lagata hai (Customer app).
Usage: python3 tool/patch_manifest.py android/app/src/main/AndroidManifest.xml "App Name"
(App ka naam workflow ke APP_NAME se aata hai - ek hi jagah se badalta hai.)
"""
import re
import sys
from xml.sax.saxutils import quoteattr

path = sys.argv[1]
app_name = sys.argv[2] if len(sys.argv) > 2 else 'Customer App'
s = open(path, encoding='utf-8').read()

# Customer ko background location nahi chahiye: area chunne ke liye sirf foreground GPS (button dabane par).
PERMS = [
    'android.permission.INTERNET',
    'android.permission.POST_NOTIFICATIONS',     # order status alert (Android 13+), Phase C11
    'android.permission.VIBRATE',
    'android.permission.ACCESS_COARSE_LOCATION',
    'android.permission.ACCESS_FINE_LOCATION',
]
add = ''.join(f'    <uses-permission android:name="{p}"/>\n' for p in PERMS if p not in s)

# Android 11+ package visibility: link kholna (https) aur call (tel)
INTENTS = '''        <intent><action android:name="android.intent.action.VIEW"/><data android:scheme="https"/></intent>
        <intent><action android:name="android.intent.action.DIAL"/><data android:scheme="tel"/></intent>
'''
if '<queries>' in s:
    if 'android.intent.action.DIAL' not in s:
        s = s.replace('<queries>', '<queries>\n' + INTENTS, 1)
else:
    add += '    <queries>\n' + INTENTS + '    </queries>\n'

if add:
    if '<application' not in s:
        sys.exit('AndroidManifest.xml mein <application nahi mila')
    s = s.replace('<application', add + '    <application', 1)

# Push notification: FCM ka default channel (server customer_push.py 'order_updates' / 'offers' par bhejta hai)
META = '<meta-data android:name="com.google.firebase.messaging.default_notification_channel_id" android:value="order_updates"/>'
if 'default_notification_channel_id' not in s:
    if '</application>' not in s:
        sys.exit('AndroidManifest.xml mein </application> nahi mila')
    s = s.replace('</application>', '        ' + META + '\n    </application>', 1)

# app ka naam (phone par icon ke neeche)
if not re.search(r'android:label="[^"]*"', s):
    sys.exit('AndroidManifest.xml mein android:label nahi mila')
s = re.sub(r'android:label="[^"]*"', 'android:label=' + quoteattr(app_name), s, count=1)

open(path, 'w', encoding='utf-8').write(s)
print('manifest patched')
