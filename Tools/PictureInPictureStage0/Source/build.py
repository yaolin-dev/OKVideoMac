from pathlib import Path
import argparse, hashlib, json, plistlib, subprocess, tempfile

source = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description='Build the isolated, local-only Release PiP API probe.')
parser.add_argument('--output', type=Path, help='Fresh output directory; defaults to a fresh temporary directory.')
args = parser.parse_args()
root = args.output.resolve() if args.output else Path(tempfile.mkdtemp(prefix='OKVideoMac-PiP-Probe-', dir='/private/tmp'))
if args.output and root.exists():
    parser.error('Output must be fresh to avoid overwriting a running or previously verified prototype.')
(root/'Evidence').mkdir(parents=True, exist_ok=True)
app = root / 'Build' / 'OKVideo-PiP-Stage0.app'
exe = app / 'Contents' / 'MacOS' / 'PiPStage0'
exe.parent.mkdir(parents=True, exist_ok=True)
info = dict(CFBundleIdentifier='com.okvideomac.prototype.pipstage0', CFBundleName='OKVideo PiP Stage 0',
            CFBundleExecutable='PiPStage0', CFBundlePackageType='APPL', CFBundleVersion='1',
            CFBundleShortVersionString='0.0.1', LSMinimumSystemVersion='12.0', NSHighResolutionCapable=True)
(app/'Contents'/'Info.plist').write_bytes(plistlib.dumps(info))
resources = app/'Contents'/'Resources'
resources.mkdir(parents=True, exist_ok=True)
fixture = resources/'control.mov'
if not fixture.exists() or fixture.stat().st_size < 1024:
    fixture_tool = root/'Build'/'generate-fixture'
    subprocess.run(['/usr/bin/xcrun', 'swiftc', '-O', '-module-cache-path', str(root/'Build'/'ModuleCache'),
                    str(source/'fixture.swift'), '-o', str(fixture_tool)], check=True)
    pending = resources/'control.partial.mov'
    pending.unlink(missing_ok=True)
    subprocess.run([str(fixture_tool), str(pending)], check=True)
    pending.replace(fixture)
cmd = ['/usr/bin/xcrun', 'swiftc', '-swift-version', '5', '-O', '-g', '-target', 'arm64-apple-macosx12.0',
       '-module-cache-path', str(root/'Build'/'ModuleCache'), str(source/'main.swift'),
       '-framework', 'AppKit', '-framework', 'AVKit', '-framework', 'AVFoundation', '-o', str(exe)]
subprocess.run(cmd, check=True)
subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(app)], check=True)
subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
(root/'Evidence'/'build.json').write_text(json.dumps(dict(configuration='Release', optimized=True, app=str(app),
    binarySHA256=hashlib.sha256(exe.read_bytes()).hexdigest(),
    sourceSHA256={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(source.glob('*')) if p.is_file()},
    desktopReplaced=False, published=False, githubUpdated=False), indent=2))
print(app)
