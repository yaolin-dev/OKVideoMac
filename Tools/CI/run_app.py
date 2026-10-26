#!/usr/bin/env python3
"""Compile the main Release App and helpers in isolation; never package, install or publish."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import time

from build_support import copy_tracked
from run_core import ROOT, command


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work-dir', type=Path, required=True)
    parser.add_argument('--dependencies', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--bridge-input', type=Path, required=True)
    parser.add_argument('--xcodegen', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    args.dependencies.mkdir(parents=True, exist_ok=True)
    report = dict(schema=1, suite='Main App Release compile', status='failed', configuration='Release',
                  compileOnly=True, codeSigningAllowed=False, stages=[])
    started = time.monotonic()
    try:
        commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
        report['sourceCommit'] = commit
        report['xcodeVersion'] = subprocess.check_output(['xcodebuild', '-version'], text=True).strip()
        if not report['xcodeVersion'].startswith('Xcode 16.2\n'):
            raise RuntimeError('Select Xcode 16.2 with DEVELOPER_DIR')
        report['xcodegenVersion'] = subprocess.check_output([str(args.xcodegen), '--version'], text=True).strip()
        if report['xcodegenVersion'].split()[-1] != '2.46.0':
            raise RuntimeError('XcodeGen 2.46.0 is required')
        node = Path(shutil.which('node')).resolve()
        report['nodeVersion'] = subprocess.check_output([str(node), '--version'], text=True).strip()
        if report['nodeVersion'] != 'v22.23.0' or not (node.parent.parent / 'LICENSE').is_file():
            raise RuntimeError('A complete Node 22.23.0 distribution including LICENSE is required')
        bridge = args.bridge_input / 'bridge-compile-only-unsigned.apk'
        manifest = json.loads((args.bridge_input / 'manifest.json').read_text())
        if (manifest.get('status') != 'passed' or manifest.get('compileOnly') is not True
                or manifest.get('sourceCommit') != commit or manifest.get('skipped') != 0
                or manifest.get('tests', 0) <= 0 or sha(bridge) != manifest.get('apkSHA256')):
            raise RuntimeError('Bridge must come from a successful test job for this commit and match its SHA-256')
        source = copy_tracked(args.work_dir / 'Source')
        project = source / 'OKVideoMac/macOS/OKVideoMac'
        target_apk = source / 'OKVideoMac/Helpers/AndroidDexBridge/app/build/outputs/apk/release/app-release.apk'
        target_apk.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(bridge, target_apk)
        os.environ['OKVIDEOMAC_BUILD_ROOT'] = str(args.dependencies)
        # These runtimes are dynamically loaded and explicitly optional in project.yml.
        # Their playback and packaging gates remain part of the formal release process.
        for name in ['libmpv', 'QuickJS']:
            (args.dependencies / name).mkdir(exist_ok=True)
        def run(name, argv, timeout=600):
            item = dict(name=name, command=[str(x) for x in argv])
            report['stages'].append(item)
            item['exitCode'] = command(item['command'], args.output / (name + '.log'), timeout)
            if item['exitCode']:
                raise RuntimeError(f'{name} failed with exit {item["exitCode"]}; see {name}.log')
        run('prepare-crash-reporter', ['bash', project / 'Scripts/prepare-crash-reporter.sh'])
        sparkle = args.dependencies / 'Sparkle'
        run('prepare-sparkle', [sys.executable, project / 'Scripts/prepare-sparkle.py', '--output', sparkle])
        run('generate-project', [args.xcodegen, 'generate', '--spec', project / 'project.yml', '--project', project])
        derived = args.work_dir / 'DerivedData'
        run('build-app', ['xcodebuild', '-project', project / 'OKVideoMac.xcodeproj', '-scheme', 'OKVideoMac',
            '-configuration', 'Release', '-sdk', 'macosx', '-destination', 'generic/platform=macOS', '-jobs', '2',
            '-derivedDataPath', derived, '-clonedSourcePackagesDirPath', args.dependencies / 'SourcePackages',
            'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=YES', 'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO',
            'CODE_SIGN_IDENTITY=', f'OKVIDEOMAC_BUILD_ROOT={args.dependencies}', f'OKVIDEOMAC_SPARKLE_ROOT={sparkle}',
            f'OKVIDEOMAC_NODE_RUNTIME={node}', 'OKVIDEOMAC_CRASH_REPORT_DSN=', 'OKVIDEOMAC_UPDATE_FEED_URL=',
            'OKVIDEOMAC_UPDATE_PUBLIC_KEY=', 'OKVIDEOMAC_UPDATE_CHANNEL=unconfigured', 'build'], 1500)
        if '** BUILD SUCCEEDED **' not in (args.output / 'build-app.log').read_text(errors='replace'):
            raise RuntimeError('Missing Xcode build success result')
        app = derived / 'Build/Products/Release/OKVideoMac.app'
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        spec = (project / 'project.yml').read_text()
        for field, key in [('CFBundleShortVersionString', 'MARKETING_VERSION'), ('CFBundleVersion', 'CURRENT_PROJECT_VERSION')]:
            expected = re.search(r'^\s*' + key + r':\s*(\S+)', spec, re.M).group(1).strip('"\'')
            if str(info[field]) != expected:
                raise RuntimeError(f'Compiled {field} does not match project.yml')
        if info.get('OKCrashReportDSN') or info.get('SUFeedURL') or info.get('SUPublicEDKey'):
            raise RuntimeError('Compile-only App unexpectedly has a live service/update configuration')
        report['binaries'] = []
        for relative in ['Contents/MacOS/OKVideoMac', 'Contents/Helpers/OKVideoLivePreview', 'Contents/Helpers/OKVideoMacRelauncher']:
            path = app / relative
            architecture = subprocess.check_output(['lipo', '-archs', str(path)], text=True).strip()
            if architecture != 'arm64' or not os.access(path, os.X_OK):
                raise RuntimeError(f'Expected an executable arm64 target: {relative}')
            report['binaries'].append(dict(path=relative, architecture=architecture, sha256=sha(path)))
        if sha(app / 'Contents/Resources/AndroidDexBridge-release.apk') != manifest['apkSHA256']:
            raise RuntimeError('Embedded Bridge does not match the tested compile input')
        signing = subprocess.run(['codesign', '-dv', '--verbose=4', str(app)], capture_output=True, text=True)
        inspection = signing.stdout + signing.stderr
        (args.output / 'signing-inspection.log').write_text(inspection)
        if 'Authority=' in inspection or (app / 'Contents/_CodeSignature/CodeResources').exists():
            raise RuntimeError('Compile-only App unexpectedly has a distribution bundle signature')
        report.update(status='passed', version=info['CFBundleShortVersionString'], build=info['CFBundleVersion'])
    except Exception as error:
        report['error'] = str(error)
    report['elapsedSeconds'] = round(time.monotonic() - started, 3)
    (args.output / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
    text = f"### Main App Release compile\n\nStatus: **{report['status']}**\n\n"
    text += 'Main App, preview and relaunch helpers compiled for arm64. No signing credentials, packaging, notarization, installation or release upload.\n' if report['status'] == 'passed' else report.get('error', 'Missing result') + '\n'
    text += '\nThis gate does not validate playback, UI interaction, signed APK installation or release eligibility.\n'
    (args.output / 'summary.md').write_text(text)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as output: output.write(text)
    print(text, flush=True)
    return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
