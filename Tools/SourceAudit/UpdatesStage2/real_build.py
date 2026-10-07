#!/usr/bin/env python3
"""Build the real App with explicit, auditable test-only source instrumentation."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import probe

ROOT = Path('/private/tmp/OKVideoMac-SparkleStage2-Real')
APP_REL = Path('OKVideoMac/macOS/OKVideoMac')
BASELINE_APP = Path(os.environ['OKVIDEOMAC_UPDATE_PROBE_BASE_APP'])
NATIVE = Path(os.environ['OKVIDEOMAC_BUILD_ROOT'])

def prepare():
    ROOT.mkdir(exist_ok=True)
    source = ROOT/'Source'
    project = source/APP_REL
    if not source.exists():
        names = subprocess.check_output(['git','ls-files','-z','--cached','--others','--exclude-standard'],cwd=probe.REPO).decode().split('\0')
        records = []
        for name in sorted(set(names)):
            if not (name.startswith(str(APP_REL)+'/') or name in ('OKVideoMac/LICENSE','OKVideoMac/NOTICE.md')):
                continue
            original = probe.REPO/name
            if not original.is_file(): continue
            target = source/name
            target.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(original,target)
            records.append({'path':name,'sha256':probe.sha(original)})
        (ROOT/'source-inputs.json').write_text(json.dumps(records,indent=2)+'\n')
    # Always reset instrumented files from the current branch before applying
    # exact-match edits. Fail if the upstream code shape has changed.
    changes = []
    def edit(relative, substitutions, append=''):
        original=probe.REPO/APP_REL/relative
        text=original.read_text()
        for old,new in substitutions:
            assert text.count(old)==1, (relative,old[:90],text.count(old))
            text=text.replace(old,new)
        text+=append
        target=project/relative
        if not target.exists() or target.read_text()!=text:
            target.write_text(text)
        changes.append({'path':relative,'original_sha256':probe.sha(original),
                        'instrumented_sha256':hashlib.sha256(text.encode()).hexdigest(),
                        'replacements':[{'before':a,'after':b} for a,b in substitutions]})
    edit('App/OKVideoMacApp.swift',[
        ('await SeekAcceptanceHarness.runIfRequested(state)','await RealProbe.run(state)'),
        ('    func applicationShouldTerminate(\n','    func applicationWillTerminate(_ notification: Notification) { ProbeLog.record("will_terminate") }\n\n    func applicationShouldTerminate(\n'),
        ('        switch terminationState {','        ProbeLog.record("termination_requested")\n        switch terminationState {'),
        ('                await appState?.shutdown()','                ProbeLog.record("cleanup_started")\n                await appState?.shutdown()'),
        ('        terminationTimeoutTask?.cancel()','        ProbeLog.record("cleanup_completed")\n        terminationTimeoutTask?.cancel()'),
        ('        terminationTask?.cancel()','        ProbeLog.record("cleanup_timeout")\n        terminationTask?.cancel()'),
        ('        NSApp.reply(toApplicationShouldTerminate: true)','        ProbeLog.record("termination_replied")\n        NSApp.reply(toApplicationShouldTerminate: true)')])
    edit('App/AppEnvironment.swift',[
        ('        let directories = try runtimeDirectories()','        let directories = try RealProbe.directories()'),
        ('KeychainXtreamCredentialStore(service: acceptance == nil\n                ? KeychainXtreamCredentialStore.defaultService\n                : "com.okvideomac.acceptance.8b3b.\\(acceptance!.root.lastPathComponent)")',
         'KeychainXtreamCredentialStore(service: Bundle.main.bundleIdentifier! + ".fixture-credentials")')])
    edit('App/AppRelaunchCoordinator.swift',[
        ('    case invalidApplicationBundle','    case updateInstallationInProgress\n    case invalidApplicationBundle'),
        ('        state = .preparingHelper','        guard ProbeRestartGate.claim(String(describing: ObjectIdentifier(self))) else {\n            throw AppRelaunchError.updateInstallationInProgress\n        }\n        state = .preparingHelper'),
        ('            state = .idle','            ProbeRestartGate.release(String(describing: ObjectIdentifier(self)))\n            state = .idle')])
    edit('App/AppState.swift',[
        ('        let finalHistoryWrite = playbackHistoryWrite(position: playerSnapshot.position, duration: playerSnapshot.duration)',
         '        ProbeLog.record("appstate_shutdown_entered")\n        let finalHistoryWrite = playbackHistoryWrite(position: playerSnapshot.position, duration: playerSnapshot.duration)'),
        ('            await self.environment?.player.shutdown()',
         '            ProbeLog.record("history_flushed")\n            await self.environment?.player.shutdown()\n            ProbeLog.record("player_shutdown_completed", ["nativeReleased": self.environment?.player.renderPlayer == nil])'),
        ('            await self.environment?.nodeBundleRuntime.stop(force: true)',
         '            await self.environment?.nodeBundleRuntime.stop(force: true)\n            ProbeLog.record("node_shutdown_completed")'),
        ('            _ = await androidShutdownTask?.value',
         '            _ = await androidShutdownTask?.value\n            ProbeLog.record("android_shutdown_completed")')],
        (probe.HERE/'AppStateProbe.swift.inc').read_text())
    edit('project.yml',[
        ('      - path: Features','      - path: UpdateProbe\n      - path: Features'),
        ('    SWIFT_VERSION: "5.7"','    SWIFT_VERSION: "5.7"\n    FRAMEWORK_SEARCH_PATHS: "$(inherited) /private/tmp/OKVideoMac-SparkleStage2-Mini"\n    OTHER_LDFLAGS: "$(inherited) -framework Sparkle"\n    LD_RUNPATH_SEARCH_PATHS: "$(inherited) @executable_path/../Frameworks"')])
    (ROOT/'instrumentation.json').write_text(json.dumps(changes,indent=2)+'\n')
    (project/'UpdateProbe').mkdir(exist_ok=True)
    for name in ('ProbeDriver.swift','RealProbe.swift'):
        shutil.copy2(probe.HERE/name,project/'UpdateProbe'/name)
    apk=project/'../../Helpers/AndroidDexBridge/app/build/outputs/apk/release/app-release.apk'
    apk.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(BASELINE_APP/'Contents/Resources/AndroidDexBridge-release.apk',apk)
    probe.run(['/opt/homebrew/bin/xcodegen','generate','--spec',project/'project.yml'])
    env=dict(probe.ENV,OKVIDEOMAC_BUILD_ROOT=str(NATIVE),
             PATH='/opt/local/bin:/opt/local/sbin:'+os.environ.get('PATH',''),
             PKG_CONFIG='/opt/local/bin/pkg-config',
             PKG_CONFIG_LIBDIR='/opt/local/lib/pkgconfig:/opt/local/share/pkgconfig',
             CMAKE_PREFIX_PATH='/opt/local')
    env.pop('PKG_CONFIG_PATH',None)
    args=['xcodebuild','-project',str(project/'OKVideoMac.xcodeproj'),'-scheme','OKVideoMac',
          '-configuration','Release','-destination','platform=macOS,arch=arm64',
          '-derivedDataPath',str(ROOT/'DerivedData'),'CODE_SIGNING_ALLOWED=NO',
          'ARCHS=arm64','ONLY_ACTIVE_ARCH=YES','EXCLUDED_ARCHS=x86_64','ENABLE_CODE_COVERAGE=NO',
          'PRODUCT_BUNDLE_IDENTIFIER=com.okvideomac.sparkleprobe.realbuild','build']
    (ROOT/'build-command.json').write_text(json.dumps(args,indent=2)+'\n')
    with (ROOT/'build.log').open('w') as log:
        result=subprocess.run(args,env=env,stdout=log,stderr=subprocess.STDOUT)
    if result.returncode:
        print('\n'.join((ROOT/'build.log').read_text().splitlines()[-35:]),flush=True)
        raise RuntimeError('Real probe Release build failed; see '+str(ROOT/'build.log'))
    template=ROOT/'Template.app'
    if template.exists(): shutil.rmtree(template)
    shutil.copytree(ROOT/'DerivedData/Build/Products/Release/OKVideoMac.app',template,symlinks=True)
    # Start from the previously verified, normalized runtime, then sign every
    # fixture binary with the same Developer ID (host keeps Library Validation).
    shutil.rmtree(template/'Contents/Frameworks')
    shutil.copytree(BASELINE_APP/'Contents/Frameworks',template/'Contents/Frameworks',symlinks=True)
    shutil.copytree(probe.OUTPUT/'Sparkle.framework',template/'Contents/Frameworks/Sparkle.framework',symlinks=True)
    shutil.copy2(probe.DEPENDENCIES/'LICENSE',template/'Contents/Resources/Sparkle-LICENSE.txt')
    host=template/'Contents/MacOS/OKVideoMac'
    links=probe.run(['otool','-L',host],capture_output=True).stdout.splitlines()[1:]
    for line in links:
        dependency=line.strip().split(' (compatibility')[0]
        if dependency.startswith(('/opt/local/','/opt/homebrew/','/usr/local/')):
            target=template/'Contents/Frameworks'/Path(dependency).name
            assert target.is_file(), 'Baseline is missing a linked dependency'
            def library_uuid(path):
                return probe.run(['dwarfdump','--uuid',path],capture_output=True).stdout.split(' (')[0]
            assert library_uuid(target)==library_uuid(dependency), 'Linked library differs from verified baseline'
            probe.run(['install_name_tool','-change',dependency,'@rpath/'+target.name,host],capture_output=True)
    # Just as in package-app.sh, no host dependency may rely on a local package
    # manager at runtime. Keep library validation enabled throughout the probe.
    host_links=probe.run(['otool','-L',host],capture_output=True).stdout
    assert '/opt/homebrew/' not in host_links and '/opt/local/' not in host_links
    inventory=[]
    for path in template.rglob('*'):
        if path.is_symlink() or not path.is_file() or not probe.is_macho(path): continue
        relative=path.relative_to(template).as_posix(); inventory.append(relative)
        if '/Sparkle.framework/' in relative: continue # already signed, verified in prepare
        if relative.endswith('/NodeRuntime/node'):
            probe.run(['codesign','--force','--sign',probe.IDENTITY,'--options','runtime','--timestamp',
                       '--entitlements',project/'Supporting/NodeHelper.entitlements',path],capture_output=True)
        else: probe.sign(path)
    base_inventory={p.relative_to(BASELINE_APP).as_posix() for p in BASELINE_APP.rglob('*')
                    if p.is_file() and not p.is_symlink() and probe.is_macho(p)}
    sparkle_inventory={'Contents/Frameworks/Sparkle.framework/'+p for p in json.loads((probe.HERE/'approved-framework-paths.json').read_text())}
    assert set(inventory)==base_inventory|sparkle_inventory, 'Unexpected fixture executable inventory'
    assert len(base_inventory)==29
    (ROOT/'fixture-inventory.json').write_text(json.dumps(sorted(inventory),indent=2)+'\n')
    probe.sign(template)
    probe.run(['codesign','--verify','--deep','--strict',template])
    print('PASS: real App Release fixture compiled; exact 29 baseline + 5 Sparkle paths; not a production package',flush=True)

if __name__=='__main__': prepare()
