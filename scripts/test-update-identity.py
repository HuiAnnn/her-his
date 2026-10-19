#!/usr/bin/env python3
"""Real signing regression: different build hashes must share a certificate-bound identity."""
import pathlib
import plistlib
import shutil
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
source = root / 'build/HerHis.app'
with tempfile.TemporaryDirectory(prefix='herhis-update-test-') as directory:
    apps, requirements, hashes = [], [], []
    for version in ('update-test-1', 'update-test-2'):
        app = pathlib.Path(directory) / (version + '.app')
        shutil.copytree(source, app)
        plist = app / 'Contents/Info.plist'
        info = plistlib.loads(plist.read_bytes())
        info['CFBundleVersion'] = version
        plist.write_bytes(plistlib.dumps(info))
        subprocess.run(['bash', str(root/'scripts/sign-app.sh'), str(app)], check=True)
        result = subprocess.run(['codesign', '-d', '-r-', '--verbose=4', str(app)], check=True, capture_output=True, text=True)
        lines = (result.stdout + result.stderr).splitlines()
        requirement = next(line.split('designated => ', 1)[1] for line in lines if 'designated => ' in line)
        requirements.append(requirement)
        hashes.append(next(line for line in lines if line.startswith('CDHash=')))
        apps.append(app)
    assert hashes[0] != hashes[1], 'Fixture must represent distinct builds'
    assert requirements[0] == requirements[1], 'Updates changed application identity'
    assert 'certificate leaf' in requirements[0] and 'identifier' in requirements[0]
    subprocess.run(['codesign', '--verify', '-R', '=' + requirements[0], str(apps[1])], check=True)
    # Same identifier under an ad-hoc signature must not inherit Keychain access.
    subprocess.run(['codesign', '--force', '--sign', '-', str(apps[1])], check=True)
    rejected = subprocess.run(['codesign', '--verify', '-R', '=' + requirements[0], str(apps[1])], capture_output=True)
    assert rejected.returncode != 0, 'An unrelated signature was accepted'
    print('PASS: distinct updates share identity; ad-hoc impersonation rejected')
