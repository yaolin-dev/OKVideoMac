#!/usr/bin/env python3
"""Create the stable signed appcast from the final notarized DMG only."""
import argparse
import hashlib
import html
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

REPO = Path(__file__).resolve().parents[2]
NS = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'

def run(args):
    return subprocess.check_output([str(a) for a in args], text=True).strip()

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def validate_feed(path, dmg, version, build):
    items = ET.parse(path).findall('./channel/item')
    if len(items) != 1:
        raise ValueError('Expected exactly one release item')
    item = items[0]
    if item.findtext(NS+'version') != build or item.findtext(NS+'shortVersionString') != version:
        raise ValueError('Appcast version does not match the final App')
    enclosure = item.find('enclosure')
    expected = f'https://github.com/yaolin-dev/OKVideoMac/releases/download/v{version}/{dmg.name}'
    if enclosure is None or enclosure.get('url') != expected:
        raise ValueError('Appcast must reference the immutable GitHub release DMG')
    if enclosure.get('length') != str(dmg.stat().st_size) or not enclosure.get(NS+'edSignature'):
        raise ValueError('Appcast archive signature or byte count is missing')
    if item.find(NS+'releaseNotesLink') is not None:
        raise ValueError('Release notes must be embedded in the signed appcast')
    if not item.findtext('description'):
        raise ValueError('Missing embedded release notes')
    return enclosure.get(NS+'edSignature')

def create(dmg, app, notary_result, archive, output, notes, account):
    if json.loads(notary_result.read_text()).get('status') != 'Accepted':
        raise ValueError('Update feed requires Apple notarization Accepted')
    run(['xcrun', 'stapler', 'validate', dmg])
    run(['codesign', '--verify', '--strict', dmg])
    run(['codesign', '--verify', '--deep', '--strict', app])
    info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
    from verify_update_bundle import validate_configuration
    validate_configuration(info, require_stable=True)
    version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
    if dmg.name != f'OKVideoMac-{version}.dmg':
        raise ValueError('Unexpected DMG filename')
    lock = json.loads((REPO/'ThirdParty/sparkle-lock.json').read_text())
    if sha(archive) != lock['distribution_sha256']:
        raise ValueError('Sparkle signing tools archive hash mismatch')
    before = sha(dmg)
    with tempfile.TemporaryDirectory(prefix='okvideo-update-feed-') as directory:
        root = Path(directory)
        tools = root/'tools'; tools.mkdir()
        run(['tar','-xJf',archive,'-C',tools])
        public = run([tools/'bin/generate_keys','--account',account,'-p'])
        if public != info['SUPublicEDKey']:
            raise ValueError('Keychain public key differs from signed App configuration')
        inputs = root/'inputs'; inputs.mkdir()
        shutil.copyfile(dmg, inputs/dmg.name)
        (inputs/dmg.with_suffix('.html').name).write_text(
            '<!doctype html><meta charset="utf-8"><pre>'+html.escape(notes.read_text())+'</pre>\n')
        feed = root/'appcast.xml'
        run([tools/'bin/generate_appcast','--account',account,'--maximum-deltas','0',
             '--versions',build,'--download-url-prefix',
             f'https://github.com/yaolin-dev/OKVideoMac/releases/download/v{version}/',
             '--embed-release-notes','-o',feed,inputs])
        signature = validate_feed(feed,dmg,version,build)
        run([tools/'bin/sign_update','--account',account,'--verify',dmg,signature])
        run([tools/'bin/sign_update','--account',account,'--verify',feed])
        if before != sha(dmg):
            raise ValueError('Final stapled DMG was modified while generating feed')
        output.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(feed,output)
    print(f'PASS: signed stable appcast for {version} ({build}); final DMG unchanged')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('dmg','app','notary-result','archive','output','notes'):
        parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--account',default='OKVideoMac-release')
    args = vars(parser.parse_args())
    create(**args)
