from pathlib import Path
import hashlib, json, os, shutil, subprocess, sys
REPO=Path(__file__).resolve().parents[3]
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(REPO/'Tools/SourceAudit/UpdatesStage2'))
import probe
ROOT=Path('/private/tmp/OKVideoMac-EpisodeNavigation-Native')
APP_REL=Path('OKVideoMac/macOS/OKVideoMac')
BASE=Path(os.environ['OKVIDEOMAC_NAVIGATION_BASE_APP'])
def prepare():
    ROOT.mkdir(exist_ok=True)
    source=ROOT/'Source'
    project=source/APP_REL
    names=subprocess.check_output(['git','ls-files','-z','--cached','--others','--exclude-standard'],cwd=REPO).decode().split('\0')
    for name in sorted(set(names)):
        original=REPO/name
        if not original.is_file() or not (name.startswith(str(APP_REL)+'/') or name in ('OKVideoMac/LICENSE','OKVideoMac/NOTICE.md')): continue
        target=source/name; target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(original,target)
    changes=[]
    def edit(name,pairs,append=''):
        original=REPO/APP_REL/name; text=original.read_text()
        for old,new in pairs:
            assert text.count(old)==1,(name,old[:90],text.count(old))
            text=text.replace(old,new)
        text+=append
        (project/name).write_text(text)
        changes.append({'path':name,'original_sha256':probe.sha(original),
                        'instrumented_sha256':hashlib.sha256(text.encode()).hexdigest(),
                        'replacements':[{'before':a,'after':b} for a,b in pairs]})
    edit('App/OKVideoMacApp.swift',[
        ('                    AppUpdateCoordinator.shared.install(appState: state)', '                    // Isolated native navigation fixture: no updater checks.'),
        ('await SeekAcceptanceHarness.runIfRequested(state)', 'await NavigationProbe.run(state)')])
    edit('App/AppEnvironment.swift',[
        ('        let directories = try runtimeDirectories()', '        let directories = try NavigationProbe.directories()'),
        ('KeychainXtreamCredentialStore(service: acceptance == nil\n                ? KeychainXtreamCredentialStore.defaultService\n                : "com.okvideomac.acceptance.8b3b.\\(acceptance!.root.lastPathComponent)")',
         'KeychainXtreamCredentialStore(service: Bundle.main.bundleIdentifier! + ".fixture-credentials")')])
    edit('App/AppState.swift', [], (HERE/'AppStateProbe.swift.inc').read_text())
    shutil.copy2(HERE/'NavigationProbe.swift',project/'App/NavigationProbe.swift')
    (ROOT/'instrumentation.json').write_text(json.dumps(changes,indent=2)+'\n')
    apk=project/'../../Helpers/AndroidDexBridge/app/build/outputs/apk/release/app-release.apk'
    apk.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(BASE/'Contents/Resources/AndroidDexBridge-release.apk',apk)
    probe.run(['/opt/homebrew/bin/xcodegen','generate','--spec',project/'project.yml'])
    command=['xcodebuild','-project',str(project/'OKVideoMac.xcodeproj'),'-scheme','OKVideoMac',
             '-configuration','Release','-destination','platform=macOS,arch=arm64',
             '-derivedDataPath',str(ROOT/'DerivedData'),'CODE_SIGNING_ALLOWED=NO',
             'ARCHS=arm64','ONLY_ACTIVE_ARCH=YES','ENABLE_CODE_COVERAGE=NO',
             'OKVIDEOMAC_SPARKLE_ROOT=/private/tmp/OKVideoMac-Updates-LocalDelivery/Dependencies/Sparkle',
             'PRODUCT_BUNDLE_IDENTIFIER=com.okvideomac.episodenavigation.probe','build']
    with (ROOT/'build.log').open('w') as log:
        result=subprocess.run(command,env=probe.ENV,stdout=log,stderr=subprocess.STDOUT)
    if result.returncode: raise SystemExit('Fixture build failed; see '+str(ROOT/'build.log'))
    template=ROOT/'Template.app'
    if template.exists(): shutil.rmtree(template)
    shutil.copytree(ROOT/'DerivedData/Build/Products/Release/OKVideoMac.app',template,symlinks=True)
    shutil.rmtree(template/'Contents/Frameworks')
    shutil.copytree(BASE/'Contents/Frameworks',template/'Contents/Frameworks',symlinks=True)
    host=template/'Contents/MacOS/OKVideoMac'
    for line in probe.run(['otool','-L',host],capture_output=True).stdout.splitlines()[1:]:
        dependency=line.strip().split(' (compatibility')[0]
        if dependency.startswith(('/opt/local/','/opt/homebrew/','/usr/local/')):
            target=template/'Contents/Frameworks'/Path(dependency).name
            uuid=lambda p: probe.run(['dwarfdump','--uuid',p],capture_output=True).stdout.split(' (')[0]
            assert target.is_file() and uuid(target)==uuid(dependency)
            probe.run(['install_name_tool','-change',dependency,'@rpath/'+target.name,host],capture_output=True)
    for path in template.rglob('*'):
        if path.is_symlink() or not path.is_file() or not probe.is_macho(path): continue
        relative=path.relative_to(template).as_posix()
        if relative.startswith('Contents/Frameworks/'): continue
        if relative.endswith('/NodeRuntime/node'):
            probe.run(['codesign','--force','--sign',probe.IDENTITY,'--options','runtime','--timestamp',
                       '--entitlements',project/'Supporting/NodeHelper.entitlements',path],capture_output=True)
        else: probe.sign(path)
    probe.sign(template)
    probe.run(['codesign','--verify','--deep','--strict',template])
    print('PASS: isolated native episode-navigation Release fixture compiled and signed',flush=True)

prepare()
