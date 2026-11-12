#!/usr/bin/env python3
"""Real throw/rethrow/signal recovery and optional SDK HTTP transport, using a dedicated fixture only."""
import argparse
import gzip
import http.server
import json
from pathlib import Path
import plistlib
import re
import resource
import shutil
import subprocess
import threading


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--upload', action='store_true')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    app = args.output / 'CrashDiagnosticFixture.app'
    executable = app / 'Contents/MacOS/CrashDiagnosticFixture'
    executable.parent.mkdir(parents=True)
    shutil.copy2(args.binary, executable)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'com.okvideomac.diagnostic-fixture',
        'CFBundleExecutable': executable.name, 'CFBundlePackageType': 'APPL',
        'CFBundleVersion': '205', 'CFBundleShortVersionString': '0.9.3', 'LSUIElement': True,
    }))
    uuid = re.search(r'UUID: ([A-F0-9-]+)', subprocess.check_output(
        ['xcrun', 'dwarfdump', '--uuid', executable], text=True)).group(1)
    packets = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            data = self.rfile.read(int(self.headers['Content-Length']))
            if self.headers.get('Content-Encoding') == 'gzip':
                data = gzip.decompress(data)
            packets.append(data)
            self.send_response(503)  # Exercise pending/retry; never acknowledge a real report.
            self.end_headers()
            self.wfile.write(b'{}')

        def log_message(self, *_):
            pass

    def invoke(mode, root, *extra, crash=False):
        def no_core():
            resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        result = subprocess.run([str(executable), mode, str(root), *extra],
                                capture_output=True, text=True, preexec_fn=no_core, timeout=30)
        (args.output / (root.name + '-' + mode + '.stderr')).write_text(result.stderr)
        if crash:
            assert result.returncode < 0, (mode, result.returncode, result.stderr)
            return
        assert result.returncode == 0, (mode, result.returncode, result.stderr)
        return json.loads(result.stdout.strip().splitlines()[-1])

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler) if args.upload else None
    if server:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    cases = []
    try:
        for kind in ['throw', 'rethrow', 'signal']:
            root = args.output / kind
            invoke(kind, root, crash=True)
            recovered = invoke('recover', root)
            assert len(recovered) == 1
            report = recovered[0]
            (args.output / (kind + '-record.json')).write_text(json.dumps(report, indent=2))
            assert report['build'] == '205' and report['signal'] == 'SIGABRT'
            assert [o['kind'] for o in report['operations']] == ['launch', 'navigationLive', 'windowResizeBegin']
            assert report['operations'][-1]['window'] == 'browser'
            assert report['imageCount'] >= len(report['images'])
            native = list((root / 'native-archive').glob('*.plcrash'))
            assert len(native) == 1 and native[0].stat().st_mode & 0o777 == 0o600
            result = {'kind': kind, 'eventID': report['id'], 'operations': [o['kind'] for o in report['operations']]}
            if kind == 'signal':
                assert report.get('exception') is None
            else:
                exception = report['exception']
                assert exception['name'] == 'NSGenericException'
                assert 'Update Constraints in Window' in exception['reason']
                assert 'PRIVATE_TITLE' not in exception['reason'] and 'private.invalid' not in exception['reason']
                image = next(i for i in report['images'] if i['uuid'] == uuid)
                # PLCrashReport exception frames contain return PCs; atos needs the call instruction.
                addresses = [hex(f['pc'] - 4) for f in exception['frames'] if f.get('imageBase') == image['base']]
                resolved = subprocess.check_output(['xcrun', 'atos', '-arch', 'arm64', '-o', executable,
                    '-l', hex(image['base']), *addresses], text=True)
                assert 'ok_fixture_original_throw' in resolved, resolved
                result['firstThrowSymbols'] = resolved.splitlines()
                assert exception['frames'] != next(t for t in report['threads'] if t['crashed'])['frames']
                assert b'PRIVATE_TITLE' in native[0].read_bytes()  # Original retained locally, never sent.
            if server:
                before = len(packets)
                receipt = invoke('upload', root, f'http://public@127.0.0.1:{server.server_port}/1')
                assert receipt['handlersUnchanged'] and receipt['httpStatus'] == 503
                assert len(packets) == before + 1
                event = json.loads(packets[-1].splitlines()[-1])
                (args.output / (kind + '-event.json')).write_text(json.dumps(event, indent=2))
                assert event['event_id'] == report['id']
                assert event['environment'] == 'okvideomac-crash-integration-acceptance'
                assert event['contexts']['last_operation']['kind'] == 'windowResizeBegin'
                assert len(event['breadcrumbs']) == 3
                for forbidden in ['PRIVATE_TITLE', 'DO_NOT_SEND', 'private.invalid', '/Users/', 'token=SECRET']:
                    assert forbidden not in json.dumps(event), forbidden
                exception = event['exception']['values'][0]
                assert exception['type'] == ('SIGABRT' if kind == 'signal' else 'NSGenericException')
                assert len(list((root / 'pending').glob('*.json'))) == 1
                result['transport'] = 'SDK -> isolated worker -> HTTP 503 -> same pending event'
            cases.append(result)
        # Conversion failure must retain the unchanged native bytes instead of silently purging them.
        damaged_root = args.output / 'malformed-recovery'
        assert invoke('recover', damaged_root) == []
        slot = next((damaged_root / 'raw').rglob('live_report.plcrash'))
        malformed = b'invalid native report retained for diagnosis'
        slot.write_bytes(malformed)
        assert invoke('recover', damaged_root) == []
        assert any(p.read_bytes() == malformed for p in (damaged_root / 'native-archive').glob('*.plcrash'))
        summary = {'status': 'passed', 'malformedNativePreserved': True, 'cases': cases, 'backendSentryRequests': 0, 'loopbackPackets': len(packets)}
        (args.output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
        print(json.dumps(summary, indent=2))
    finally:
        if server:
            server.shutdown()
            server.server_close()


if __name__ == '__main__':
    main()
