#!/usr/bin/env python3
"""Build a compile-only unsigned bridge and run every Release JVM unit test."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
import zipfile

from build_support import copy_tracked
from run_core import ROOT, command


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work-dir', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--artifact-dir', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    report = dict(schema=1, suite='Android Release JVM and unsigned bridge', status='failed', compileOnly=True)
    started = time.monotonic()
    try:
        # Java 17 uses the process locale for native paths. A C locale corrupts
        # Chinese workspace paths when Gradle starts its single-use daemon.
        os.environ['LC_ALL'] = 'en_US.UTF-8' if sys.platform == 'darwin' else 'C.UTF-8'
        report['locale'] = os.environ['LC_ALL']
        signing = ['OKVIDEOMAC_ANDROID_BRIDGE_' + suffix for suffix in ['KEYSTORE', 'STORE_PASSWORD', 'KEY_ALIAS', 'KEY_PASSWORD']]
        if any(os.environ.get(key) for key in signing):
            raise RuntimeError('This CI path must not receive Android release signing inputs')
        java = Path(os.environ['JAVA_HOME']) / 'bin/java'
        version = subprocess.check_output([str(java), '-version'], text=True, stderr=subprocess.STDOUT)
        if '17.0.19' not in version:
            raise RuntimeError('Use the CI Java 17.0.19 toolchain')
        report['javaVersion'] = version.strip()
        report['sourceCommit'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
        sdk = Path(os.environ['ANDROID_HOME'])
        if not (sdk / 'platforms/android-35/android.jar').is_file() or not (sdk / 'build-tools/34.0.0/source.properties').is_file():
            raise RuntimeError('Android SDK platform 35 and AGP 8.7 build-tools 34.0.0 are required')
        source = copy_tracked(args.work_dir / 'Source', 'OKVideoMac/Helpers/AndroidDexBridge')
        argv = ['bash', str(source / 'gradlew'), '--project-dir', str(source), '--no-daemon', '--console=plain',
                '--no-build-cache', '--rerun-tasks', ':app:assembleRelease', ':app:testReleaseUnitTest']
        report['command'] = argv
        code = command(argv, args.output / 'gradle.log', 1200)
        report['exitCode'] = code
        if code:
            raise RuntimeError(f'Gradle failed with exit {code}; see gradle.log')
        report['lintMetadataDiagnostics'] = (args.output / 'gradle.log').read_text(errors='replace').count('Module was compiled with an incompatible version of Kotlin')
        files = sorted((source / 'app/build/test-results/testReleaseUnitTest').glob('TEST-*.xml'))
        if not files:
            raise RuntimeError('No Release JVM test reports')
        names = []
        for path in files:
            root = ET.parse(path).getroot()
            cases = root.findall('testcase')
            if root.tag != 'testsuite' or not cases or int(root.get('tests', '-1')) != len(cases):
                raise RuntimeError(f'Incomplete JVM test report: {path.name}')
            if any(int(root.get(key, '0')) for key in ['failures', 'errors', 'skipped', 'disabled']):
                raise RuntimeError(f'Failed or skipped JVM tests: {path.name}')
            if any(list(root.iter(tag)) for tag in ['failure', 'error', 'skipped']):
                raise RuntimeError(f'Unsuccessful JVM case: {path.name}')
            names += [case.attrib['classname'] + '/' + case.attrib['name'] for case in cases]
            shutil.copy2(path, args.output / path.name)
        if len(names) != len(set(names)):
            raise RuntimeError('Duplicate JVM test identities')
        apk = source / 'app/build/outputs/apk/release/app-release-unsigned.apk'
        with zipfile.ZipFile(apk) as archive:
            if not {'AndroidManifest.xml', 'classes.dex'} <= set(archive.namelist()):
                raise RuntimeError('Unsigned bridge APK is incomplete')
        apksigner = sdk / 'build-tools/34.0.0/apksigner'
        verification = subprocess.run([str(apksigner), 'verify', str(apk)], capture_output=True, text=True, timeout=30)
        if verification.returncode == 0:
            raise RuntimeError('CI bridge unexpectedly contains an Android signing certificate')
        if 'DOES NOT VERIFY' not in verification.stderr + verification.stdout:
            raise RuntimeError('Could not establish that APK is unsigned')
        report.update(status='passed', tests=len(names), cases=names, skipped=0,
                      apkSHA256=hashlib.sha256(apk.read_bytes()).hexdigest())
        args.artifact_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(apk, args.artifact_dir / 'bridge-compile-only-unsigned.apk')
        (args.artifact_dir / 'manifest.json').write_text(json.dumps({key:report[key] for key in
            ['schema', 'status', 'compileOnly', 'sourceCommit', 'tests', 'skipped', 'apkSHA256']}, indent=2) + '\n')
    except Exception as error:
        report['status'] = 'failed'
        report['error'] = str(error)
    report['elapsedSeconds'] = round(time.monotonic() - started, 3)
    (args.output / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
    text = f"### Android Release JVM and unsigned bridge\n\nStatus: **{report['status']}**\n\n"
    text += f"{report['tests']} JVM tests passed; no skips. Unsigned APK is only an input to the App compile check.\n" if report['status'] == 'passed' else report.get('error', 'Missing result') + '\n'
    if report.get('lintMetadataDiagnostics'):
        text += '\nAGP lint reported Kotlin dependency metadata incompatibility. Full dependency lint coverage is not established; see gradle.log.\n'
    (args.output / 'summary.md').write_text(text)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as output: output.write(text)
    print(text, flush=True)
    return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
