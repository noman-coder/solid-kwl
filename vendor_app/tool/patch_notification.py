"""flutter create ke baad "Naye orders" notification ki alag awaaz + notification ka rang lagata hai (Phase V7).

Usage: python3 tool/patch_notification.py android

Kya karta hai:
  1. tool/res/new_order.wav ko android/app/src/main/res/raw/new_order.wav mein copy karta hai
     (app 'new_orders' channel isi awaaz se banati hai: push.dart mein RawResourceAndroidNotificationSound).
  2. res/raw/keep.xml: release build (resource shrinker) is awaaz ko 'unused' samajh kar hata na de.
  3. res/values/vendor_notification.xml: notification ka teal rang.
  4. AndroidManifest.xml mein FCM ka default notification rang.

Koi cheez na mile to build ko ghalat karne ke bajaye saaf error deta hai.
"""
import os
import shutil
import sys

android_dir = sys.argv[1] if len(sys.argv) > 1 else 'android'
here = os.path.dirname(os.path.abspath(__file__))
src_wav = os.path.join(here, 'res', 'new_order.wav')
res = os.path.join(android_dir, 'app', 'src', 'main', 'res')
manifest = os.path.join(android_dir, 'app', 'src', 'main', 'AndroidManifest.xml')

if not os.path.exists(src_wav):
    sys.exit('tool/res/new_order.wav nahi mili')
if not os.path.exists(manifest):
    sys.exit('AndroidManifest.xml nahi mila: ' + manifest)

# 1) awaaz
raw = os.path.join(res, 'raw')
os.makedirs(raw, exist_ok=True)
shutil.copyfile(src_wav, os.path.join(raw, 'new_order.wav'))

# 2) shrinker se bachao
with open(os.path.join(raw, 'keep.xml'), 'w', encoding='utf-8') as f:
    f.write('<?xml version="1.0" encoding="utf-8"?>\n'
            '<resources xmlns:tools="http://schemas.android.com/tools" tools:keep="@raw/new_order" />\n')

# 3) rang
values = os.path.join(res, 'values')
os.makedirs(values, exist_ok=True)
with open(os.path.join(values, 'vendor_notification.xml'), 'w', encoding='utf-8') as f:
    f.write('<?xml version="1.0" encoding="utf-8"?>\n'
            '<resources>\n'
            '    <color name="vendor_notification_color">#0F766E</color>\n'
            '</resources>\n')

# 4) manifest meta-data (FCM default colour)
s = open(manifest, encoding='utf-8').read()
META = ('<meta-data android:name="com.google.firebase.messaging.default_notification_color" '
        'android:resource="@color/vendor_notification_color"/>')
if 'default_notification_color' not in s:
    if '</application>' not in s:
        sys.exit('AndroidManifest.xml mein </application> nahi mila')
    s = s.replace('</application>', '        ' + META + '\n    </application>', 1)
    open(manifest, 'w', encoding='utf-8').write(s)

print('notification awaaz + rang laga diya (res/raw/new_order.wav)')
