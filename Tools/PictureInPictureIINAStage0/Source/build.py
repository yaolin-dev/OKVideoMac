from pathlib import Path
import argparse,hashlib,json,math,plistlib,shutil,struct,subprocess,tempfile,wave

parser=argparse.ArgumentParser(description='Build an isolated IINA-style mpv PiP experiment; never install/publish.')
parser.add_argument('--output',type=Path,required=True)
parser.add_argument('--fixture',type=Path,help='Reuse a locally generated synthetic fixture')
parser.add_argument('--source-app',type=Path,required=True,help='Previously verified local Release bundle, read-only input')
parser.add_argument('--bridge-header',type=Path,required=True)
args=parser.parse_args()
root=args.output.resolve()
if root.exists(): parser.error('Output must be fresh')
source=Path(__file__).resolve().parent
app=root/'Build'/'OKVideo-PiP-IINA-Stage0.app'
exe=app/'Contents'/'MacOS'/'PiPIINAStage0'
exe.parent.mkdir(parents=True)
resources=app/'Contents'/'Resources'; resources.mkdir()
frameworks=app/'Contents'/'Frameworks'; frameworks.mkdir()
(root/'Evidence').mkdir()
def run(cmd): subprocess.run([str(x) for x in cmd],check=True,timeout=180)
def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()
inputs={}
for lib in sorted((args.source_app/'Contents'/'Frameworks').glob('*.dylib')):
    inputs[lib.name]=digest(lib)
    shutil.copy2(lib,frameworks/lib.name)
header=root/'Build'/'OKMPVBridge.h'; shutil.copy2(args.bridge_header,header)
inputs['OKMPVBridge.h']=digest(header)
with wave.open(str(root/'Build'/'tone.wav'),'wb') as wav:
    wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(48000)
    frames=bytearray()
    for i in range(12*48000):
        t=i/48000; phase=t%1
        envelope=max(0,min(1,phase/0.005,(0.10-phase)/0.005)) if phase<0.10 else 0
        frames+=struct.pack('<h',int(32767*0.15*envelope*math.sin(2*math.pi*660*t)))
    wav.writeframes(frames)
generator=root/'Build'/'generate-fixture'
run(['/usr/bin/xcrun','swiftc','-O','-module-cache-path',root/'Build'/'ModuleCache',source/'fixture.swift','-o',generator])
if args.fixture:
    shutil.copy2(args.fixture,resources/'fixture.mov')
    inputs['fixture.mov']=digest(args.fixture)
else:
    run([generator,root/'Build'/'silent.mov',root/'Build'/'tone.wav',resources/'fixture.mov'])
info=dict(CFBundleIdentifier='com.okvideomac.prototype.pipiina0',CFBundleName='OKVideo PiP IINA Stage 0',
    CFBundleExecutable='PiPIINAStage0',CFBundlePackageType='APPL',CFBundleVersion='1',CFBundleShortVersionString='0.0.1',
    LSMinimumSystemVersion='12.0',NSHighResolutionCapable=True)
(app/'Contents'/'Info.plist').write_bytes(plistlib.dumps(info))
run(['/usr/bin/xcrun','clang','-O2','-g','-fobjc-arc','-Wno-deprecated-declarations','-mmacosx-version-min=12.0',
    '-I',root/'Build',source/'main.m','-framework','AppKit','-framework','OpenGL','-L',frameworks,
    '-lOKMPVBridge','-Wl,-rpath,@executable_path/../Frameworks','-o',exe])
for lib in sorted(frameworks.glob('*.dylib')): run(['/usr/bin/codesign','--force','--sign','-',lib])
run(['/usr/bin/codesign','--force','--sign','-',app])
run(['/usr/bin/codesign','--verify','--deep','--strict',app])
deps=subprocess.check_output(['/usr/bin/otool','-L',str(exe)],text=True)
assert '/PrivateFrameworks/PIP' not in deps
(root/'Evidence'/'build.json').write_text(json.dumps(dict(configuration='Release',optimization='-O2',
    inputsSHA256=inputs,sourceSHA256={p.name:digest(p) for p in source.iterdir() if p.is_file()},binarySHA256=digest(exe),
    privateFrameworkStaticLink=False,privateFrameworkBundled=False,desktopReplaced=False,published=False,githubUpdated=False),indent=2)+'\n')
print(app)
