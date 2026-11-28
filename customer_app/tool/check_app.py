"""Customer app ki chhoti static jaanch (Flutter / Dart ke baghair chalti hai). Workflow build se pehle chalata hai.

Usage (customer_app/ folder se):  python3 tool/check_app.py

Kya dekhta hai:
  1. lib/ ki har .dart file mein ( ) { } [ ] barabar hon (strings / comments / ${...} ka khayal rakh kar).
  2. Har import mil jaye: relative file maujood ho, package pubspec.yaml mein ho (flutter / dart: sdk wale chhor kar).
  3. Server ka URL sirf services/api.dart mein ho (app ki screens mein kahin nahi - customer ko dikhna nahi chahiye).
  4. Secret / private key ka koi nishan nahi (license_private, google-services.json, key.properties, keystore).
  5. print( nahi (debugPrint use hota hai).
  6. pubspec ka naam / app id / zaroori files (workflow, patch scripts, icons) maujood.
Koi masla ho to saaf line + file ke saath bata kar exit code 1.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, 'lib')
errors = []


def err(msg):
    errors.append(msg)


# ------------------------------------------------------------------ 1. brackets

PAIRS = {')': '(', '}': '{', ']': '['}


def check_brackets(path, src):
    """Dart source ke brackets: strings, comments, raw strings aur '${ ... }' ke andar ke code ka khayal."""
    stack = []          # (char, line)
    i, n, line = 0, len(src), 1

    def fail(msg):
        err(f'{rel(path)}:{line}: {msg}')

    def skip_string(i, line):
        """src[i] string ka pehla quote hai; string ke baad wali position (aur line) lautao.
        ${...} ke andar ka code bhi bracket-check hota hai (recursive)."""
        raw = i > 0 and src[i - 1] == 'r' and (i < 2 or not (src[i - 2].isalnum() or src[i - 2] == '_'))
        q = src[i]
        triple = src[i:i + 3] == q * 3
        end = q * 3 if triple else q
        i += len(end)
        while i < n:
            c = src[i]
            if c == '\n':
                line += 1
                if not triple:
                    fail('string line ke andar band nahi hui')
                    return i + 1, line
            if not raw and c == '\\':
                i += 2
                continue
            if src.startswith(end, i):
                return i + len(end), line
            if not raw and c == '$' and src[i + 1:i + 2] == '{':
                depth, i = 1, i + 2
                while i < n and depth:
                    ch = src[i]
                    if ch == '\n':
                        line += 1
                    if ch in '\'"':
                        i, line = skip_string(i, line)
                        continue
                    if ch == '{':
                        depth += 1
                    elif ch == '}':
                        depth -= 1
                    i += 1
                continue
            i += 1
        fail('string band nahi hui')
        return i, line

    while i < n:
        c = src[i]
        if c == '\n':
            line += 1
            i += 1
        elif src.startswith('//', i):
            while i < n and src[i] != '\n':
                i += 1
        elif src.startswith('/*', i):
            j = src.find('*/', i + 2)
            if j < 0:
                fail('/* comment band nahi hua')
                return
            line += src.count('\n', i, j)
            i = j + 2
        elif c in '\'"':
            i, line = skip_string(i, line)
        elif c in '({[':
            stack.append((c, line))
            i += 1
        elif c in ')}]':
            if not stack:
                fail(f'faltu "{c}"')
                return
            o, ol = stack.pop()
            if o != PAIRS[c]:
                fail(f'"{c}" aya magar "{o}" (line {ol}) khula tha')
                return
            i += 1
        else:
            i += 1
    for o, ol in stack:
        err(f'{rel(path)}:{ol}: "{o}" band nahi hua')


def rel(p):
    return os.path.relpath(p, ROOT).replace(os.sep, '/')


# ------------------------------------------------------------------ pubspec

pub_path = os.path.join(ROOT, 'pubspec.yaml')
pub = open(pub_path, encoding='utf-8').read() if os.path.exists(pub_path) else ''
if not pub:
    err('pubspec.yaml nahi mila')
if not re.search(r'^name:\s*kconn_customer\s*$', pub, re.M):
    err('pubspec.yaml: name kconn_customer hona chahiye (workflow --project-name se milta)')
deps = set()
m = re.search(r'^dependencies:\s*\n((?:[ \t]+.*\n|\n)+)', pub, re.M)
if m:
    for ln in m.group(1).splitlines():
        mm = re.match(r'^  ([a-z_0-9]+):', ln)
        if mm:
            deps.add(mm.group(1))

# ------------------------------------------------------------------ dart files

dart_files = []
for base, _d, files in os.walk(LIB):
    for f in files:
        if f.endswith('.dart'):
            dart_files.append(os.path.join(base, f))
dart_files.sort()
if not dart_files:
    err('lib/ mein koi .dart file nahi')

IMPORT_RE = re.compile(r'''^\s*(?:import|export|part)\s+['"]([^'"]+)['"]''', re.M)
for path in dart_files:
    src = open(path, encoding='utf-8').read()
    check_brackets(path, src)
    for imp in IMPORT_RE.findall(src):
        if imp.startswith('dart:'):
            continue
        if imp.startswith('package:'):
            pkg = imp[len('package:'):].split('/')[0]
            if pkg not in deps and pkg not in ('flutter', 'kconn_customer'):
                err(f'{rel(path)}: package "{pkg}" pubspec.yaml ki dependencies mein nahi')
            if pkg == 'kconn_customer':
                target = os.path.join(LIB, imp.split('/', 1)[1])
                if not os.path.exists(target):
                    err(f'{rel(path)}: import nahi mila: {imp}')
            continue
        target = os.path.normpath(os.path.join(os.path.dirname(path), imp))
        if not os.path.exists(target):
            err(f'{rel(path)}: import ki file nahi mili: {imp}')
    if re.search(r'(?<![A-Za-z_.])print\(', src):
        err(f'{rel(path)}: print( mat likhein, debugPrint use karein')
    if rel(path) != 'lib/services/api.dart' and re.search(r'khanewal|https?://', src, re.I):
        for ln_no, ln in enumerate(src.splitlines(), 1):
            if re.search(r'khanewal|https?://', ln, re.I) and not ln.lstrip().startswith('//') \
                    and not ln.lstrip().startswith('///'):
                err(f'{rel(path)}:{ln_no}: server URL / naam sirf services/api.dart mein ho (customer ko nahi dikhna chahiye)')
    if re.search(r'license_private|google-services\.json|key\.properties|\.jks|\.keystore', src):
        err(f'{rel(path)}: secret / key ka zikr app code mein nahi hona chahiye')

# ------------------------------------------------------------------ zaroori files

for need in ('pubspec.yaml', 'assets/icon/app_icon.png', 'assets/icon/app_icon_fg.png', 'lib/main.dart',
             'lib/theme.dart', 'lib/services/api.dart', 'lib/services/app_state.dart',
             'lib/screens/login.dart', 'lib/screens/register.dart', 'lib/screens/otp.dart',
             'lib/screens/forgot.dart', 'lib/screens/shell.dart', 'lib/screens/home_tab.dart',
             'lib/screens/area_picker.dart', 'lib/models/home.dart',
             'lib/screens/stores_tab.dart', 'lib/screens/store_detail.dart', 'lib/models/stores.dart',
             'lib/widgets/store_card.dart', 'lib/widgets/store_product_tile.dart',
             'tool/patch_gradle.py', 'tool/patch_manifest.py', 'tool/patch_push.py',
             'tool/patch_notification.py'):
    if not os.path.exists(os.path.join(ROOT, need)):
        err(f'zaroori file nahi mili: {need}')

# pubspec mein jo asset likha hai wo maujood ho
for a in re.findall(r'^\s*-\s*(assets/[^\s#]+)', pub, re.M):
    if not os.path.exists(os.path.join(ROOT, a)):
        err(f'pubspec.yaml ka asset nahi mila: {a}')

# workflow
wf = os.path.join(os.path.dirname(ROOT), '.github', 'workflows', 'build_customer_apk.yml')
if os.path.exists(wf):
    w = open(wf, encoding='utf-8').read()
    if "APP_ID: 'com.khanewal.customer.app'" not in w:
        err('build_customer_apk.yml: APP_ID com.khanewal.customer.app nahi')
    if 'GOOGLE_SERVICES_JSON_CUSTOMER' not in w:
        err('build_customer_apk.yml: GOOGLE_SERVICES_JSON_CUSTOMER secret nahi')
    if 'name: customer-apk' not in w:
        err('build_customer_apk.yml: artifact customer-apk nahi')
# (CI mein repo checkout hota hai, is liye workflow hamesha milti hai; sirf customer_app akeli copy ho to chhor do)

# repo mein secret file na ho
for base, _d, files in os.walk(ROOT):
    for f in files:
        if f in ('license_private.key', 'key.properties', 'google-services.json') or f.endswith(('.jks', '.keystore')):
            err(f'secret file customer_app mein nahi honi chahiye: {rel(os.path.join(base, f))}')

if errors:
    print('JAANCH NAAKAM:')
    for e in errors:
        print(' -', e)
    sys.exit(1)
print(f'JAANCH THEEK: {len(dart_files)} dart files, brackets / imports / server URL / secrets sab sahi.')
