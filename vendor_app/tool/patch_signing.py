"""flutter create ke baad release signing lagata hai (Play Store ke liye signed AAB / APK).

Usage: python3 tool/patch_signing.py android/app

- `build.gradle.kts` (ya purani `build.gradle`) mein `android/key.properties` padhne wali signingConfig 'release' jodta hai
  aur release buildType ko usi se sign karwata hai (pehle debug key se hota tha).
- key.properties / keystore is script ka kaam nahi: workflow GitHub Secrets se banata hai. Repo / zip mein kabhi nahi jate.
- Dobara chalane par kuch nahi badalta (idempotent). Pattern na mile to saaf error (chupke ghalat sign nahi hota).
"""
import os
import re
import sys

app_dir = sys.argv[1]
MARK = 'vendor-release-signing'

KTS_IMPORTS = f'''// {MARK}
import java.io.FileInputStream
import java.util.Properties

'''
KTS_HEAD = '''val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

'''
KTS_CFG = '''    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            storeFile = keystoreProperties["storeFile"]?.let { file(it as String) }
            storePassword = keystoreProperties["storePassword"] as String?
        }
    }

'''
GROOVY_HEAD = f'''// {MARK}
def keystoreProperties = new Properties()
def keystorePropertiesFile = rootProject.file('key.properties')
if (keystorePropertiesFile.exists()) {{
    keystoreProperties.load(new FileInputStream(keystorePropertiesFile))
}}

'''
GROOVY_CFG = '''    signingConfigs {
        release {
            keyAlias keystoreProperties['keyAlias']
            keyPassword keystoreProperties['keyPassword']
            storeFile keystoreProperties['storeFile'] ? file(keystoreProperties['storeFile']) : null
            storePassword keystoreProperties['storePassword']
        }
    }

'''

for name in ('build.gradle.kts', 'build.gradle'):
    p = os.path.join(app_dir, name)
    if not os.path.exists(p):
        continue
    s = open(p, encoding='utf-8').read()
    if MARK in s:
        print(f'{name}: signing pehle se laga hai')
        sys.exit(0)
    kts = name.endswith('.kts')
    # 1) signingConfigs android { ke andar, buildTypes se pehle
    m = re.search(r'^([ \t]*)buildTypes\s*\{', s, re.M)
    if not m:
        sys.exit(f'{name}: buildTypes nahi mila - signing nahi lag saka')
    s = s[:m.start()] + (KTS_CFG if kts else GROOVY_CFG) + s[m.start():]
    # 2) release ko debug ki jagah release key se sign karo
    if kts:
        s, n = re.subn(r'signingConfig\s*=\s*signingConfigs\.getByName\("debug"\)',
                       'signingConfig = signingConfigs.getByName("release")', s, count=1)
    else:
        s, n = re.subn(r'signingConfig\s+signingConfigs\.debug', 'signingConfig signingConfigs.release', s, count=1)
    if not n:
        sys.exit(f'{name}: release signingConfig (debug) nahi mili - gradle file dekhein')
    # plugins { } sabse pehle rehna chahiye: imports sabse upar, properties android { } se theek pehle
    a = re.search(r'^android\s*\{', s, re.M)
    if not a:
        sys.exit(f'{name}: android {{ block nahi mila - signing nahi lag saka')
    s = s[:a.start()] + (KTS_HEAD if kts else GROOVY_HEAD) + s[a.start():]
    if kts:
        s = KTS_IMPORTS + s
    open(p, 'w', encoding='utf-8').write(s)
    print(f'{name}: release signing laga di')
    break
else:
    sys.exit('build.gradle(.kts) nahi mila')
