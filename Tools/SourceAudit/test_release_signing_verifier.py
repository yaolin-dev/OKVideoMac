"""Exercise verifier pipefail handling and rejection gates with long diagnostics."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'OKVideoMac/macOS/OKVideoMac/Scripts/verify-release-signing.sh'

class SigningVerifierTests(unittest.TestCase):
    def run_verifier(self, **settings):
        with tempfile.TemporaryDirectory(prefix='OKVideoMac-Signing-Test-', dir='/private/tmp') as tmp:
            root = Path(tmp); app = root / 'OKVideoMac.app'; bins = root / 'bin'; bins.mkdir()
            for name in ['Contents/MacOS/OKVideoMac', 'Contents/Resources/NodeRuntime/node', 'Contents/Helpers/OKVideoMacRelauncher', 'Contents/Helpers/OKVideoLivePreview']:
                if settings.get('MISSING_PREVIEW') and name.endswith('/OKVideoLivePreview'): continue
                target = app / name; target.parent.mkdir(parents=True, exist_ok=True); target.write_text('fixture'); target.chmod(0o755)
            commands = {
                'file': '#!/bin/sh\nprintf "%s: Mach-O 64-bit executable arm64\\n" "$1"\n',
                'lipo': '#!/bin/sh\necho arm64\n',
                'codesign': '''#!/usr/bin/python3
import os, sys
args=sys.argv[1:]; target=args[-1]
if '--verify' in args:
    sys.exit(1 if os.environ.get('BAD_SIGNATURE') else 0)
if '--entitlements' in args:
    key='com.apple.security.cs.allow-jit' if target.endswith('/node') else 'com.apple.security.cs.disable-library-validation'
    extra='<key>com.apple.security.get-task-allow</key><true/>' if os.environ.get('FORBIDDEN_ENTITLEMENT') else ''
    print('<?xml version="1.0"?><plist version="1.0"><dict><key>'+key+'</key><true/>'+extra+'</dict></plist>')
else:
    print('CodeDirectory v=20500 size=100 flags=0x10002(adhoc,runtime) hashes=1')
    print('TeamIdentifier=not set')
    print('Signature=adhoc')
    # A producer must not be killed by the first matched awk/grep line.
    print('Diagnostic='+'x'*131072)
''',
            }
            for name, body in commands.items():
                path=bins/name;path.write_text(body);path.chmod(0o755)
            env=dict(os.environ,PATH=str(bins)+':'+os.environ['PATH'],**settings)
            return subprocess.run(['bash',str(SCRIPT),'--mode','local',str(app)],env=env,
                                  stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=30)

    def test_long_diagnostics_do_not_trigger_sigpipe(self):
        result=self.run_verifier()
        self.assertEqual(result.returncode,0,result.stdout[-3000:])
        self.assertIn('Signing verification passed (4 Mach-O objects',result.stdout)

    def test_missing_preview_helper_is_rejected(self):
        result=self.run_verifier(MISSING_PREVIEW='1')
        self.assertEqual(result.returncode,1,result.stdout[-1000:])
        self.assertIn('preview helper',result.stdout.lower())

    def test_invalid_nested_signature_is_still_rejected(self):
        result=self.run_verifier(BAD_SIGNATURE='1')
        self.assertEqual(result.returncode,1,result.stdout[-1000:])
        self.assertIn('FAIL: invalid nested signature:',result.stdout)

    def test_forbidden_entitlement_is_still_rejected(self):
        result=self.run_verifier(FORBIDDEN_ENTITLEMENT='1')
        self.assertEqual(result.returncode,1,result.stdout[-1000:])
        self.assertIn('FAIL: main app contains forbidden entitlement:',result.stdout)

if __name__=='__main__': unittest.main()
