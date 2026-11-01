#!/usr/bin/env python3
"""Run the explicit critical-user-flow contract in Release, without installing or publishing."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import sys
import time

from run_core import ROOT, command as bounded_command
from test_results import xctest_results, write_junit


def selected_tests(plan, group):
    if plan.get('schema') != 1 or plan.get('target') != 'OKVideoMacTests':
        raise ValueError('Unsupported critical-flow contract')
    groups = plan['groups']
    all_ids = [identity for entries in groups.values() for identity in entries]
    if set(groups) != {'logic', 'desktop'} or any(not entries for entries in groups.values()):
        raise ValueError('Both regression groups must be nonempty')
    if len(all_ids) != len(set(all_ids)) or any(
            not re.fullmatch(r'[A-Za-z_]\w*/test\w+', identity) for identity in all_ids):
        raise ValueError('Duplicate or invalid regression identity')
    return all_ids if group == 'all' else groups[group]


def verify_source_contract(project, identities):
    # The plan is intentionally a reviewed list of complete user-flow assertions,
    # not a test-count threshold. A deleted/renamed test must fail before execution.
    source = '\n'.join(p.read_text() for p in (project / 'Tests').glob('*.swift'))
    for identity in identities:
        suite, method = identity.split('/')
        if not re.search(r'\bclass\s+' + re.escape(suite) + r'\s*:\s*XCTestCase\b', source):
            raise ValueError('Missing regression suite: ' + suite)
        if not re.search(r'\bfunc\s+' + re.escape(method) + r'\s*\(', source):
            raise ValueError('Missing regression method: ' + identity)


def validate_results(log, identities, returncode):
    if '** TEST EXECUTE SUCCEEDED **' not in log:
        raise ValueError('Xcode did not report a completed test execution')
    return xctest_results(log, {'OKVideoMacTests.' + identity for identity in identities}, {},
                          returncode, completed_suite='Selected tests')


def source_fingerprint(project):
    files = [project / 'project.yml', project / 'OKVideoMac.xcodeproj/project.pbxproj']
    for folder in ['App', 'Features', 'Engines', 'Player', 'Tests', 'Packages', 'Supporting', 'Resources']:
        files.extend(p for p in (project / folder).rglob('*') if p.is_file()
                     and not any(part.startswith('.') for part in p.relative_to(project).parts)
                     and p.suffix in {'.swift', '.m', '.h', '.xcstrings', '.plist', '.entitlements'})
    digest = hashlib.sha256()
    for path in sorted(set(files)):
        digest.update(str(path.relative_to(project)).encode() + b'\0')
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


def validate_test_host(info, configuration):
    if info['CFBundleIdentifier'] == 'com.okvideomac.OKVideoMac':
        raise ValueError('Refusing to use the installed/public application as a test host')
    if configuration.get('TestHostBundleIdentifier') != info['CFBundleIdentifier']:
        raise ValueError('Xcode cached a different test host identity; use a fresh DerivedData directory')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project', type=Path, default=ROOT / 'OKVideoMac/macOS/OKVideoMac')
    parser.add_argument('--derived-data', type=Path, required=True)
    parser.add_argument('--source-packages', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--group', choices=['logic', 'desktop', 'all'], default='logic')
    parser.add_argument('--skip-build', action='store_true')
    parser.add_argument('--build-setting', action='append', default=[])
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    report = dict(schema=1, status='failed', configuration='Release', group=args.group,
                  realMediaPlayback=False, published=False, stages=[])
    started = time.monotonic()

    def run(name, command, timeout=1800):
        report['stages'].append(dict(name=name, command=[str(x) for x in command]))
        code = bounded_command(command, args.output / (name + '.log'), timeout)
        report['stages'][-1]['exitCode'] = code
        return code

    try:
        plan = json.loads((ROOT / 'Tools/CI/critical-user-flows.json').read_text())
        identities = selected_tests(plan, args.group)
        report['expectedTests'] = identities
        verify_source_contract(args.project, identities)
        fingerprint = source_fingerprint(args.project)
        report['sourceFingerprint'] = fingerprint
        stamp = args.derived_data / 'critical-regression-build.json'
        if args.skip_build:
            previous = json.loads(stamp.read_text())
            if previous.get('sourceFingerprint') != fingerprint:
                raise RuntimeError('Test host is stale: rebuild after changing App or test sources')
        (args.output / 'contract.json').write_text(json.dumps(plan, indent=2) + '\n')
        if not args.skip_build:
            settings = ['ENABLE_TESTABILITY=YES', 'ENABLE_HARDENED_RUNTIME=NO',
                        'OTHER_SWIFT_FLAGS=$(inherited) -j2 -DOKVIDEO_PERFORMANCE_TEST',
                        'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_IDENTITY=-',
                        'CODE_SIGN_ENTITLEMENTS=' + str(args.project / 'Supporting/OKVideoMac.dev.entitlements'),
                        'OTHER_CODE_SIGN_FLAGS=--deep', 'ENABLE_CODE_COVERAGE=NO',
                        'OKVIDEOMAC_APP_BUNDLE_IDENTIFIER=com.okvideomac.OKVideoMac.regression',
                        'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=YES']
            command = ['xcodebuild', '-project', str(args.project / 'OKVideoMac.xcodeproj'),
                       '-scheme', 'OKVideoMac', '-configuration', 'Release',
                       '-destination', 'platform=macOS,arch=arm64', '-jobs', '2',
                       '-derivedDataPath', str(args.derived_data)]
            if args.source_packages:
                command += ['-clonedSourcePackagesDirPath', str(args.source_packages)]
            # Test builds are ad-hoc signed and isolated from the delivered app.
            if run('build', command + settings + args.build_setting + ['build-for-testing']):
                raise RuntimeError('Release test build failed; see build.log')
        products = args.derived_data / 'Build/Products'
        manifests = list(products.glob('*.xctestrun'))
        if len(manifests) != 1:
            raise RuntimeError('Expected exactly one freshly built xctestrun manifest')
        info = plistlib.loads((products / 'Release/OKVideoMac.app/Contents/Info.plist').read_bytes())
        configuration = plistlib.loads(manifests[0].read_bytes())['OKVideoMacTests']
        validate_test_host(info, configuration)
        # These contracts substitute the provider and decoder. Local build roots
        # can contain partially embedded native libraries with absolute build
        # dependencies; never dlopen those during fixture startup. CI already
        # omits these optional runtimes. Full runtimes belong to the separate
        # verified Release package and real-media acceptance, not this test host.
        report['optionalRuntimePolicy'] = 'disabled-for-fixture-tests'
        if not args.skip_build:
            app = products / 'Release/OKVideoMac.app'
            for name in ['libOKMPVBridge.dylib', 'libmpv.dylib', 'libOKQuickJS.dylib']:
                library = app / 'Contents/Frameworks' / name
                if library.exists():
                    library.unlink()
            if run('sign-test-host', ['codesign', '--force', '--deep', '--sign', '-', '--timestamp=none',
                    '--entitlements', str(args.project / 'Supporting/OKVideoMac.dev.entitlements'), str(app)], 120):
                raise RuntimeError('Unable to sign isolated fixture test host')
            if run('verify-test-host', ['codesign', '--verify', '--deep', '--strict', str(app)], 120):
                raise RuntimeError('Isolated fixture host signature verification failed')
        binary_hash = hashlib.sha256((products / 'Release/OKVideoMac.app/Contents/MacOS/OKVideoMac').read_bytes()).hexdigest()
        test_hash = hashlib.sha256((products / 'Release/OKVideoMac.app/Contents/PlugIns/OKVideoMacTests.xctest/Contents/MacOS/OKVideoMacTests').read_bytes()).hexdigest()
        manifest_hash = hashlib.sha256(manifests[0].read_bytes()).hexdigest()
        if args.skip_build:
            if (previous.get('binarySHA256') != binary_hash or previous.get('manifestSHA256') != manifest_hash
                    or previous.get('testBundleSHA256') != test_hash):
                raise RuntimeError('Test host or manifest changed since the verified test build')
        elif source_fingerprint(args.project) != fingerprint:
            raise RuntimeError('Sources changed during the Release test build')
        else:
            stamp.write_text(json.dumps(dict(sourceFingerprint=fingerprint, binarySHA256=binary_hash,
                                            manifestSHA256=manifest_hash, testBundleSHA256=test_hash), indent=2) + '\n')
        report.update(version=info['CFBundleShortVersionString'], build=info['CFBundleVersion'])
        command = ['xcodebuild', 'test-without-building', '-xctestrun', str(manifests[0]),
                   '-destination', 'platform=macOS,arch=arm64', '-parallel-testing-enabled', 'NO',
                   '-test-timeouts-enabled', 'YES', '-default-test-execution-time-allowance', '60',
                   '-maximum-test-execution-time-allowance', '90', '-resultBundlePath',
                   str(args.output / 'tests.xcresult')]
        command += ['-only-testing:OKVideoMacTests/' + identity for identity in identities]
        code = run('tests', command)
        log = (args.output / 'tests.log').read_text(errors='replace')
        result = validate_results(log, identities, code)
        if source_fingerprint(args.project) != fingerprint:
            raise RuntimeError('Sources changed during regression execution')
        write_junit(args.output / 'junit.xml', result, 'Critical user flows: ' + args.group)
        report.update(result, status='passed')
    except Exception as error:
        report['error'] = str(error)
        # Native input prerequisites are a failure, never an implicit test skip/pass.
        log = (args.output / 'tests.log').read_text(errors='replace') if (args.output / 'tests.log').exists() else ''
        if 'Fixture must receive native input' in log:
            report['failureCategory'] = 'desktop-focus-unavailable'
    report['elapsedSeconds'] = round(time.monotonic() - started, 3)
    (args.output / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
    message = f"Critical user flows ({args.group}): {report['status']}; "
    message += f"{report['passed']} passed, zero skips" if report['status'] == 'passed' else report['error']
    print(message, flush=True)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as output:
            output.write('\n' + message + '\n')
    return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__':
    sys.exit(main())
