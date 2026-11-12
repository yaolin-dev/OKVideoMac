"""Synthetic Swift/C captures, local atos, and real SDK packets to a loopback sink only."""
import gzip
import http.server
import json
import os
from pathlib import Path
import re
import resource
import subprocess
import tempfile
import threading

ROOT = Path('/private/tmp/OKVideoMac-CrashIntegration')
AREA = ROOT / 'Stage7Acceptance'
EXE = AREA / 'OKVideoMac.app/Contents/MacOS/OKVideoMac'
manifest = json.loads((AREA / 'archive/manifest.json').read_text())
results = []
packets = []


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        data = self.rfile.read(int(self.headers['Content-Length']))
        if self.headers.get('Content-Encoding') == 'gzip':
            data = gzip.decompress(data)
        packets.append(data)
        self.send_response(503)
        self.end_headers()
        self.wfile.write(b'{}')

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
dsn = f'http://public@127.0.0.1:{server.server_port}/1'


def no_core():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def invoke(root, *args, crash=False):
    env = os.environ.copy()
    env.pop('XCTestBundlePath', None)
    env.pop('XCTestConfigurationFilePath', None)
    env['OKVIDEOMAC_8B3B_ROOT'] = str(root)
    p = subprocess.run([str(EXE), *args], env=env, capture_output=True, text=True,
                       preexec_fn=no_core, timeout=20)
    if crash:
        assert p.returncode < 0, p.stderr[-400:]
    else:
        assert p.returncode == 0, p.stderr[-400:]
        return json.loads(p.stdout.strip().splitlines()[-1])


try:
    for kind in ['swift', 'c']:
        root = Path(tempfile.mkdtemp(prefix=f'OKVideoMac-8B3B-symbol-{kind}-', dir='/private/tmp'))
        invoke(root, '--diagnostic-crash-stage', 'entry', '--diagnostic-crash-kind', kind, crash=True)
        recovered = invoke(root, '--diagnostic-export')
        assert recovered['recovered'] and not recovered['consent'] and not recovered['businessInitialized']
        record = recovered['reports'][0]
        assert record['version'] == '0.8.4' and record['build'] == '1377001'
        relative = 'Contents/MacOS/OKVideoMac' if kind == 'swift' else 'Contents/Frameworks/libCrashAcceptanceFixture.dylib'
        symbol = next(x for x in manifest['images_before_strip'] if x['path'] == relative)['symbols'][0]
        image = next(x for x in record['images'] if x['uuid'] == symbol['uuid'])
        frames = next(x for x in record['threads'] if x['crashed'])['frames']
        addresses = [hex(f['pc']) for f in frames if f.get('imageBase') == image['base']]
        assert addresses
        resolved = subprocess.check_output(['xcrun', 'atos', '-arch', 'arm64', '-o',
            str(AREA / 'archive' / symbol['dwarf']), '-l', hex(image['base']), *addresses], text=True)
        expected = 'CrashAcceptance.swift' if kind == 'swift' else 'CrashFixture.c'
        assert re.search(re.escape(expected) + r':\d+', resolved), resolved
        assert ('faultIfRequested' if kind == 'swift' else 'ok_crash_acceptance_fault') in resolved
        local = invoke(root, '--diagnostic-upload-model', '--diagnostic-grant', '--diagnostic-test-dsn', dsn)
        assert local['pending'] == 1 and local['consent'] and not local['cacheExists']
        event = json.loads(packets[-1].splitlines()[-1])
        assert event['event_id'] == record['id']
        assert event['environment'] == 'okvideomac-crash-integration-acceptance'
        assert event['release'] == 'com.okvideomac.OKVideoMac@0.8.4+1377001'
        assert set(event) == {'contexts', 'debug_meta', 'dist', 'environment', 'event_id',
                              'exception', 'level', 'platform', 'release', 'threads', 'timestamp', 'breadcrumbs'}
        for forbidden in ['/Users/', 'DO_NOT_SEND', 'token=secret', 'example.invalid', 'Application Support']:
            assert forbidden not in json.dumps(event)
        results.append({'kind': kind, 'root': str(root), 'event_id': record['id'],
                        'uuid': symbol['uuid'], 'local_frames': resolved.splitlines(),
                        'loopback_http': 503, 'retry_pending': True, 'status': 'PASS'})
    (ROOT / 'stage7-local-symbolication.json').write_text(json.dumps({
        'status': 'PASS', 'cases': results, 'sentry_requests': 0,
        'backend_symbolication': 'NOT_TESTED', 'app': str(EXE.parent.parent.parent),
        'environment': 'okvideomac-crash-integration-acceptance',
        'release': 'com.okvideomac.OKVideoMac@0.8.4+1377001'}, indent=2) + '\n')
    print('PASS: Swift/C source lines and UUIDs; private packet allowlist; pending same-ID retries; zero Sentry requests')
finally:
    server.shutdown()
    server.server_close()
