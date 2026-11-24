"""flutter create ke baad AndroidManifest.xml mein zaroori permissions + app name lagata hai.
Usage: python3 tool/patch_manifest.py android/app/src/main/AndroidManifest.xml
"""
import re
import sys

path = sys.argv[1]
s = open(path, encoding='utf-8').read()

PERMS = [
    'android.permission.INTERNET',
    'android.permission.ACCESS_COARSE_LOCATION',
    'android.permission.ACCESS_FINE_LOCATION',
    'android.permission.ACCESS_BACKGROUND_LOCATION',
    'android.permission.FOREGROUND_SERVICE',
    'android.permission.FOREGROUND_SERVICE_LOCATION',
    'android.permission.POST_NOTIFICATIONS',
    'android.permission.WAKE_LOCK',
    'android.permission.VIBRATE',
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

# Push notification: FCM ka default channel (app mein Push.init() isi naam ka high-importance channel banata hai)
META = '<meta-data android:name="com.google.firebase.messaging.default_notification_channel_id" android:value="new_orders"/>'
if 'default_notification_channel_id' not in s:
    s = s.replace('</application>', '        ' + META + '\n    </application>', 1)

# http server bhi chale (https behtar hai)
if 'usesCleartextTraffic' not in s:
    s = s.replace('<application', '<application android:usesCleartextTraffic="true"', 1)

# app ka naam (phone par icon ke neeche)
s = re.sub(r'android:label="[^"]*"', 'android:label="88 Riders"', s, count=1)

open(path, 'w', encoding='utf-8').write(s)
print('manifest patched')
