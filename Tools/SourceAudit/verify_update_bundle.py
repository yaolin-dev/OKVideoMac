#!/usr/bin/env python3
"""Verify updater policy and the independent, exact executable allowlist."""
import argparse
import base64
import json
from pathlib import Path
import plistlib
import subprocess
from urllib.parse import urlsplit
from approved_inventory import require_approved

def validate_configuration(info, require_stable=False):
    expected={'SUAutomaticallyUpdate':False,'SUAllowsAutomaticUpdates':False,
              'SUScheduledCheckInterval':86400,'SUEnableSystemProfiling':False,
              'SUVerifyUpdateBeforeExtraction':True,'SURequireSignedFeed':True,
              'SUSignedFeedFailureExpirationInterval':0}
    for key,value in expected.items():
        if key not in info or info[key] != value or type(info[key]) != type(value):
            raise ValueError(f'Updater policy mismatch: {key}')
    if 'SUEnableAutomaticChecks' in info:
        raise ValueError('Automatic checks must retain user consent')
    channel=info.get('OKUpdateChannel')
    if require_stable and channel != 'stable':
        raise ValueError('Distribution requires a configured stable update feed')
    raw=info.get('SUFeedURL','')
    key=info.get('SUPublicEDKey','')
    if channel == 'unconfigured' and not raw and not key:
        return
    url=urlsplit(raw)
    if url.username or url.password or url.fragment:
        raise ValueError('Feed URL must not embed credentials or a fragment')
    if channel == 'stable':
        if url.scheme != 'https' or not url.hostname: raise ValueError('Stable feed must use HTTPS')
    elif channel == 'local-test':
        if url.scheme != 'http' or url.hostname != '127.0.0.1' or not url.port:
            raise ValueError('Local test feed must use an explicit loopback port')
    else:
        raise ValueError('Unknown update channel')
    if len(base64.b64decode(key,validate=True)) != 32:
        raise ValueError('Expected a 32-byte Ed25519 public key')

def verify(app, require_stable=False):
    actual=set()
    for path in (app/'Contents').rglob('*'):
        if path.is_symlink() or not path.is_file(): continue
        if 'Mach-O' in subprocess.check_output(['file','-b',str(path)],text=True):
            actual.add(path.relative_to(app).as_posix())
    count=require_approved(actual)
    info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
    validate_configuration(info, require_stable=require_stable)
    framework=app/'Contents/Frameworks/Sparkle.framework'
    version=plistlib.loads((framework/'Resources/Info.plist').read_bytes())['CFBundleShortVersionString']
    if version != '2.10.0': raise ValueError('Unapproved Sparkle framework version')
    lock=Path(__file__).resolve().parents[2]/'ThirdParty/sparkle-lock.json'
    receipt=json.loads((app/'Contents/Resources/Legal/Compliance/SPARKLE_PROVENANCE.json').read_text())
    expected=json.loads(lock.read_text())
    for key in ('version','commit','distribution_sha256'):
        if receipt[key] != expected[key]: raise ValueError(f'Stale Sparkle provenance: {key}')
    return count

if __name__ == '__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--app',type=Path,required=True)
    parser.add_argument('--require-stable', action='store_true')
    args=parser.parse_args()
    print(verify(args.app, require_stable=args.require_stable))
