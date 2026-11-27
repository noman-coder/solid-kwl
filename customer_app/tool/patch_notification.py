"""flutter create ke baad notification ka rang lagata hai (Customer app, narangi).

Usage: python3 tool/patch_notification.py android

Kya karta hai:
  1. res/values/customer_notification.xml: notification ka narangi rang.
  2. AndroidManifest.xml mein FCM ka default notification rang.
Customer app ki alert awaaz Android ki default hai (alag .wav nahi - vendor app wali "naye order" awaaz sirf vendor ke liye hai).

Koi cheez na mile to build ko ghalat karne ke bajaye saaf error deta hai.
"""
import os
import sys

android_dir = sys.argv[1] if len(sys.argv) > 1 else 'android'
res = os.path.join(android_dir, 'app', 'src', 'main', 'res')
manifest = os.path.join(android_dir, 'app', 'src', 'main', 'AndroidManifest.xml')

if not os.path.exists(manifest):
    sys.exit('AndroidManifest.xml nahi mila: ' + manifest)

values = os.path.join(res, 'values')
os.makedirs(values, exist_ok=True)
with open(os.path.join(values, 'customer_notification.xml'), 'w', encoding='utf-8') as f:
    f.write('<?xml version="1.0" encoding="utf-8"?>\n'
            '<resources>\n'
            '    <color name="customer_notification_color">#E8590C</color>\n'
            '</resources>\n')

s = open(manifest, encoding='utf-8').read()
META = ('<meta-data android:name="com.google.firebase.messaging.default_notification_color" '
        'android:resource="@color/customer_notification_color"/>')
if 'default_notification_color' not in s:
    if '</application>' not in s:
        sys.exit('AndroidManifest.xml mein </application> nahi mila')
    s = s.replace('</application>', '        ' + META + '\n    </application>', 1)
    open(manifest, 'w', encoding='utf-8').write(s)

print('notification rang laga diya')
