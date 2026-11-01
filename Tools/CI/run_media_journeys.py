#!/usr/bin/env python3
"""Run real App playback journeys against loopback fixtures, never the installed App."""
import argparse
import hashlib
import http.server
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import threading
import time
from urllib.parse import urlsplit

from run_core import ROOT, command
from run_app_regressions import source_fingerprint, validate_results, validate_test_host, verify_source_contract
from test_results import write_junit


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class FixtureServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    def __init__(self, fixtures):
        self.fixtures = fixtures.resolve()
        self.recovered = False
        self.requests = []
        self.slow_requests = 0
        super().__init__(('127.0.0.1', 0), FixtureHandler)


class FixtureHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        if self.path != '/control/recover':
            self.send_error(404); return
        self.server.recovered = True
        self.send_response(204); self.end_headers()

    def do_HEAD(self):
        self.respond(False)

    def do_GET(self):
        self.respond(True)

    def respond(self, body):
        path = urlsplit(self.path).path
        original = path
        if path == '/control/status':
            data = json.dumps({'slowRequests': self.server.slow_requests}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            if body: self.wfile.write(data)
            return
        if path.startswith('/recoverable/'):
            if not self.server.recovered:
                self.send_error(503); return
            path = path.removeprefix('/recoverable')
        if path.startswith('/slow/'):
            self.server.slow_requests += 1
            time.sleep(2)
            path = path.removeprefix('/slow')
        target = (self.server.fixtures / path.lstrip('/')).resolve()
        if not target.is_relative_to(self.server.fixtures) or not target.is_file():
            self.send_error(404); return
        data = target.read_bytes()
        start, end = 0, len(data) - 1
        value = self.headers.get('Range')
        if value:
            match = re.fullmatch(r'bytes=(\d+)-(\d*)', value)
            if not match:
                self.send_error(416); return
            start = int(match[1]); end = min(end, int(match[2])) if match[2] else end
        if start > end:
            self.send_error(416); return
        if len(self.server.requests) < 8192:
            self.server.requests.append(dict(path=original, range=value, bytes=end-start+1))
        self.send_response(206 if value else 200)
        self.send_header('Content-Type', 'application/dash+xml' if target.suffix == '.mpd' else 'video/mp4')
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Length', str(end-start+1))
        if value: self.send_header('Content-Range', f'bytes {start}-{end}/{len(data)}')
        self.end_headers()
        if body:
            try: self.wfile.write(data[start:end+1])
            except (BrokenPipeError, ConnectionResetError): pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--derived-data', type=Path, required=True)
    parser.add_argument('--runtime-app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output = args.output.resolve()
    if args.output.is_relative_to(ROOT):
        raise ValueError('Use an isolated output directory outside source')
    args.output.mkdir(parents=True, exist_ok=False)
    report = dict(schema=1, status='failed', realMediaPlayback=True, configuration='Release', published=False)
    started = time.monotonic(); server = None
    def run(name, argv, timeout=180):
        code = command([str(x) for x in argv], args.output / (name+'.log'), timeout)
        if code: raise RuntimeError(f'{name} failed ({code}); see log')
    try:
        project = ROOT / 'OKVideoMac/macOS/OKVideoMac'
        plan = json.loads((ROOT / 'Tools/CI/media-user-flows.json').read_text())
        identities = plan['tests']
        if plan['schema'] != 1 or not identities or len(identities) != len(set(identities)):
            raise ValueError('Invalid media journey contract')
        verify_source_contract(project, identities)
        stamp = json.loads((args.derived_data / 'critical-regression-build.json').read_text())
        if stamp['sourceFingerprint'] != source_fingerprint(project):
            raise ValueError('Rebuild test host after source changes')
        products = args.derived_data / 'Build/Products'
        manifests = list(products.glob('*.xctestrun'))
        if len(manifests) != 1: raise ValueError('Expected one test manifest')
        source_app = products / 'Release/OKVideoMac.app'
        info = plistlib.loads((source_app / 'Contents/Info.plist').read_bytes())
        manifest = plistlib.loads(manifests[0].read_bytes())
        validate_test_host(info, manifest['OKVideoMacTests'])
        for key, path in [('binarySHA256', source_app/'Contents/MacOS/OKVideoMac'),
                          ('testBundleSHA256', source_app/'Contents/PlugIns/OKVideoMacTests.xctest/Contents/MacOS/OKVideoMacTests'),
                          ('manifestSHA256', manifests[0])]:
            if stamp[key] != digest(path): raise ValueError('Stale or modified test host: '+key)
        run('runtime-signature', ['codesign', '--verify', '--deep', '--strict', args.runtime_app])
        report.update(sourceFingerprint=stamp['sourceFingerprint'], version=info['CFBundleShortVersionString'], build=info['CFBundleVersion'], expectedTests=identities)
        output_products = args.output / 'Products'; output_products.mkdir()
        host = output_products / 'Release/OKVideoMac.app'
        shutil.copytree(source_app, host, symlinks=True)
        for name in ['OKVideoLivePreview', 'OKVideoMacRelauncher']:
            original = products / 'Release' / name
            if original.exists(): shutil.copy2(original, output_products / 'Release' / name)
        report['runtimeInputs'] = {}
        for library in (args.runtime_app / 'Contents/Frameworks').glob('*.dylib'):
            destination = host / 'Contents/Frameworks' / library.name
            if destination.exists() or destination.is_symlink(): destination.unlink()
            shutil.copy2(library, destination)
            report['runtimeInputs'][library.name] = digest(library)
        for name in ['libOKMPVBridge.dylib', 'libmpv.dylib', 'libavcodec.61.dylib']:
            if name not in report['runtimeInputs']: raise ValueError('Missing native runtime: '+name)
        run('sign-host', ['codesign', '--force', '--deep', '--sign', '-', '--timestamp=none',
                         '--entitlements', project/'Supporting/OKVideoMac.dev.entitlements', host])
        run('verify-host', ['codesign', '--verify', '--deep', '--strict', host])
        fixtures = project / 'Native/DASHSmoke/fixtures'
        for name, expected in json.loads((fixtures/'SHA256.json').read_text()).items():
            if digest(fixtures/name) != expected: raise ValueError('Fixture changed: '+name)
        server = FixtureServer(fixtures)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        config = manifest['OKVideoMacTests']
        config.setdefault('EnvironmentVariables', {})['OKVIDEO_JOURNEY_HTTP'] = f'http://127.0.0.1:{server.server_port}'
        config['EnvironmentVariables']['OKVIDEO_JOURNEY_FIXTURES'] = str(fixtures)
        test_run = output_products / manifests[0].name
        test_run.write_bytes(plistlib.dumps(manifest))
        argv = ['xcodebuild', 'test-without-building', '-xctestrun', test_run,
                '-destination', 'platform=macOS,arch=arm64', '-parallel-testing-enabled', 'NO',
                '-test-timeouts-enabled', 'YES', '-default-test-execution-time-allowance', '180',
                '-maximum-test-execution-time-allowance', '240', '-resultBundlePath', args.output/'tests.xcresult']
        argv += ['-only-testing:OKVideoMacTests/'+x for x in identities]
        code = command([str(x) for x in argv], args.output/'tests.log', 900)
        result = validate_results((args.output/'tests.log').read_text(errors='replace'), identities, code)
        write_junit(args.output/'junit.xml', result, 'Real media playback journeys')
        if not any(x['range'] for x in server.requests): raise ValueError('No real HTTP byte-range traffic')
        if source_fingerprint(project) != stamp['sourceFingerprint']: raise ValueError('Source changed during run')
        report.update(result, status='passed')
    except Exception as error:
        report['error'] = str(error)
    finally:
        if server:
            server.shutdown(); server.server_close()
            (args.output/'http-requests.json').write_text(json.dumps(server.requests, indent=2)+'\n')
    report['elapsedSeconds'] = round(time.monotonic()-started, 3)
    (args.output/'summary.json').write_text(json.dumps(report, indent=2)+'\n')
    print('Real media journeys:', report['status'], report.get('error', str(report.get('passed', 0))+' passed'), flush=True)
    return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
