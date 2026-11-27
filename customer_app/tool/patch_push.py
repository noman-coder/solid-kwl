"""flutter create ke baad push notification ke liye Android gradle patch.

Usage: python3 tool/patch_push.py android com.khanewal.customer.app

Kya karta hai:
  1. HAMESHA: "core library desugaring" on karta hai (flutter_local_notifications ko chahiye).
  2. Agar android/app/google-services.json maujood ho:
       - check karta hai ke us ka package name APP_ID se milta hai
       - Google Services gradle plugin lagata hai (Firebase config ke liye)
     Maujood na ho to sirf warning - APK ban jati hai, bas push band rehta hai.

Kisi cheez ka format na milay to build ko ghalat karne ke bajaye saaf error deta hai.
"""
import json
import os
import re
import sys

android_dir = sys.argv[1]
app_id = sys.argv[2] if len(sys.argv) > 2 else ''
app_dir = os.path.join(android_dir, 'app')

DESUGAR_VER = '2.1.4'
GMS_VER = '4.4.2'


def read(path):
    with open(path, encoding='utf-8') as f:
        return f.read()


def write(path, text):
    with open(path, 'w', encoding='utf-8') as f:
        f.write(text)


def find(folder, *names):
    for n in names:
        p = os.path.join(folder, n)
        if os.path.exists(p):
            return p
    return None


# ------------------------------------------------------------ app/build.gradle(.kts)
app_gradle = find(app_dir, 'build.gradle.kts', 'build.gradle')
if not app_gradle:
    sys.exit('android/app/build.gradle(.kts) nahi mila')
kts = app_gradle.endswith('.kts')
s = read(app_gradle)

# 1) desugaring flag
if 'oreLibraryDesugaringEnabled' not in s:
    flag = 'isCoreLibraryDesugaringEnabled = true' if kts else 'coreLibraryDesugaringEnabled true'
    if re.search(r'compileOptions\s*\{', s):
        s = re.sub(r'(compileOptions\s*\{)', r'\1\n        ' + flag, s, count=1)
    elif re.search(r'android\s*\{', s):
        s = re.sub(r'(android\s*\{)', r'\1\n    compileOptions {\n        ' + flag + '\n    }', s, count=1)
    else:
        sys.exit('android { } block nahi mila (desugaring)')

# 2) desugar library dependency
if 'coreLibraryDesugaring(' not in s and "coreLibraryDesugaring '" not in s:
    dep = (f'coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:{DESUGAR_VER}")' if kts
           else f"coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:{DESUGAR_VER}'")
    s += f'\ndependencies {{\n    {dep}\n}}\n'
print(f'desugaring on ({os.path.basename(app_gradle)})')

# ------------------------------------------------------------ Firebase (google-services)
gs_json = os.path.join(app_dir, 'google-services.json')
if not os.path.exists(gs_json):
    write(app_gradle, s)
    print('WARNING: google-services.json nahi - push notification is APK mein band rahegi.')
    sys.exit(0)

try:
    gs = json.loads(read(gs_json))
except ValueError:
    sys.exit('google-services.json valid JSON nahi (GOOGLE_SERVICES_JSON secret dobara paste karein)')
pkgs = [c.get('client_info', {}).get('android_client_info', {}).get('package_name')
        for c in gs.get('client', [])]
if app_id and app_id not in pkgs:
    sys.exit(f'google-services.json mein package "{app_id}" nahi mila (mila: {pkgs}). '
             f'Firebase mein Android app isi package name se banayein.')

# plugin version settings.gradle(.kts) ke plugins { } mein
settings = find(android_dir, 'settings.gradle.kts', 'settings.gradle')
if not settings:
    sys.exit('android/settings.gradle(.kts) nahi mila')
st = read(settings)
if 'com.google.gms.google-services' not in st:
    m = re.search(r'^([ \t]*)id\s*\(?\s*"com\.android\.application"\s*\)?[^\n]*apply false[^\n]*$', st, re.M)
    if not m:
        sys.exit('settings.gradle mein com.android.application plugin line nahi mili - '
                 'google-services plugin khud lagana hoga')
    ind = m.group(1)
    line = (f'{ind}id("com.google.gms.google-services") version "{GMS_VER}" apply false' if settings.endswith('.kts')
            else f'{ind}id "com.google.gms.google-services" version "{GMS_VER}" apply false')
    st = st[:m.end()] + '\n' + line + st[m.end():]
    write(settings, st)

# plugin app/build.gradle ke plugins { } mein
if 'com.google.gms.google-services' not in s:
    m = re.search(r'^([ \t]*)id\s*\(?\s*"com\.android\.application"\s*\)?[^\n]*$', s, re.M)
    if not m:
        sys.exit('app/build.gradle mein com.android.application plugin line nahi mili')
    ind = m.group(1)
    line = f'{ind}id("com.google.gms.google-services")' if kts else f'{ind}id "com.google.gms.google-services"'
    s = s[:m.end()] + '\n' + line + s[m.end():]
write(app_gradle, s)
print(f'google-services plugin laga diya (package {app_id})')
