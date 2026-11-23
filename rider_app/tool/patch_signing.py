"""Release signing lagata hai (flutter create ke baad). key.properties + upload-keystore.jks pehle bani honi chahiye.
Usage: python3 tool/patch_signing.py android/app
Flutter ke naye (build.gradle.kts) aur purane (build.gradle) dono template chalte hain.
"""
import os
import re
import sys

app = sys.argv[1]
kts = os.path.join(app, 'build.gradle.kts')
groovy = os.path.join(app, 'build.gradle')

if os.path.exists(kts):
    path = kts
    s = open(path, encoding='utf-8').read()
    if 'keystoreProperties' in s:
        print('already patched'); sys.exit(0)
    s = 'import java.io.FileInputStream\nimport java.util.Properties\n\n' + s
    loader = '''val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

'''
    cfg = '''    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String
            keyPassword = keystoreProperties["keyPassword"] as String
            storeFile = file(keystoreProperties["storeFile"] as String)
            storePassword = keystoreProperties["storePassword"] as String
        }
    }

'''
    s, n1 = re.subn(r'(?m)^android\s*\{', lambda m: loader + 'android {', s, count=1)
    s, n2 = re.subn(r'(?m)^(\s*)buildTypes\s*\{', lambda m: cfg + m.group(0), s, count=1)
    s, n3 = re.subn(r'signingConfig\s*=\s*signingConfigs\.getByName\("debug"\)',
                    'signingConfig = signingConfigs.getByName("release")', s, count=1)
else:
    path = groovy
    s = open(path, encoding='utf-8').read()
    if 'keystoreProperties' in s:
        print('already patched'); sys.exit(0)
    loader = '''def keystoreProperties = new Properties()
def keystorePropertiesFile = rootProject.file('key.properties')
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(new FileInputStream(keystorePropertiesFile))
}

'''
    cfg = '''    signingConfigs {
        release {
            keyAlias keystoreProperties['keyAlias']
            keyPassword keystoreProperties['keyPassword']
            storeFile file(keystoreProperties['storeFile'])
            storePassword keystoreProperties['storePassword']
        }
    }

'''
    s, n1 = re.subn(r'(?m)^android\s*\{', lambda m: loader + 'android {', s, count=1)
    s, n2 = re.subn(r'(?m)^(\s*)buildTypes\s*\{', lambda m: cfg + m.group(0), s, count=1)
    s, n3 = re.subn(r'signingConfig\s+signingConfigs\.debug', 'signingConfig signingConfigs.release', s, count=1)

if not (n1 and n2 and n3):
    sys.exit(f'signing patch fail: android={n1} buildTypes={n2} signingConfig={n3} in {path}')
open(path, 'w', encoding='utf-8').write(s)
print('signing patched:', path)
