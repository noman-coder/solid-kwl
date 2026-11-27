"""flutter create ke baad Android applicationId (package name) set karta hai.
Usage: python3 tool/patch_gradle.py android/app com.khanewal.vendor.app
(Sirf applicationId badalta hai - namespace / MainActivity ko nahi chhedta, is liye build safe rehta hai.)
"""
import os
import re
import sys

app_dir, app_id = sys.argv[1], sys.argv[2]
done = False
for name in ('build.gradle.kts', 'build.gradle'):
    p = os.path.join(app_dir, name)
    if not os.path.exists(p):
        continue
    s = open(p, encoding='utf-8').read()
    new, n = re.subn(r'applicationId\s*=?\s*"[^"]*"', f'applicationId = "{app_id}"', s, count=1)
    if n:
        open(p, 'w', encoding='utf-8').write(new)
        print(f'applicationId = {app_id}  ({name})')
        done = True
        break
if not done:
    sys.exit('applicationId nahi mila - build.gradle dekhein')
