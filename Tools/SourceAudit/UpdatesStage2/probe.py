#!/usr/bin/env python3
"""Isolated, signed Sparkle lifecycle probes; never install to Desktop."""
import argparse
import functools
import hashlib
import http.server
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import threading
import time
import uuid
import wave
import xml.etree.ElementTree as ET

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
OUTPUT = Path('/private/tmp/OKVideoMac-SparkleStage2-Mini')
DEPENDENCIES = Path('/private/tmp/OKVideoMac-SparkleStage2-Dependencies')
IDENTITY = os.environ.get('OKVIDEOMAC_UPDATE_PROBE_IDENTITY', '')
ENV = dict(os.environ, LANG='C', LC_ALL='C')
REAL = False

def executable(app):
    return app/'Contents/MacOS'/('OKVideoMac' if REAL else 'UpdateProbe')

def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], env=ENV, check=True, text=True, **kwargs)

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def sign(path):
    assert IDENTITY and IDENTITY != '-', 'Set OKVIDEOMAC_UPDATE_PROBE_IDENTITY to a Developer ID identity'
    run(['codesign','--force','--sign',IDENTITY,'--options','runtime','--timestamp',path], capture_output=True)

def is_macho(path):
    return 'Mach-O' in run(['file','-b',path],capture_output=True).stdout

def prepare():
    OUTPUT.mkdir(exist_ok=True)
    assert sha(Path('/private/tmp/ok-sparkle-2.10.0.tar.xz')) == 'c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c'
    framework = OUTPUT/'Sparkle.framework'
    if not framework.exists():
        shutil.copytree(DEPENDENCIES/'Sparkle.framework', framework, symlinks=True)
        inventory = []
        for path in framework.rglob('*'):
            if path.is_symlink() or not path.is_file() or not is_macho(path):
                continue
            inventory.append(path.relative_to(framework).as_posix())
            arch = run(['lipo','-archs',path], capture_output=True).stdout.strip()
            if arch != 'arm64':
                thin = path.with_suffix('.arm64-incoming')
                run(['lipo',path,'-thin','arm64','-output',thin])
                thin.replace(path)
            sign(path)
        for nested in sorted([p for p in framework.rglob('*') if p.is_dir() and not p.is_symlink() and p.suffix in ('.app','.xpc')], key=lambda p: len(p.parts), reverse=True):
            sign(nested)
        sign(framework)
        run(['codesign','--verify','--deep','--strict',framework])
        (OUTPUT/'framework-inventory.json').write_text(json.dumps(sorted(inventory),indent=2)+'\n')
    run(['codesign','--verify','--deep','--strict',framework])
    actual={p.relative_to(framework).as_posix() for p in framework.rglob('*')
            if p.is_file() and not p.is_symlink() and is_macho(p)}
    assert actual==set(json.loads((HERE/'approved-framework-paths.json').read_text()))
    run(['xcrun','swiftc','-O','-parse-as-library','-target','arm64-apple-macos12.0',
         '-F',OUTPUT,'-framework','Sparkle','-framework','AppKit',
         '-Xlinker','-rpath','-Xlinker','@executable_path/../Frameworks',
         HERE/'ProbeDriver.swift',HERE/'MiniApp.swift','-o',OUTPUT/'UpdateProbe'])
    key = OUTPUT/'test-private-key.txt'
    if not key.exists():
        run(['xcrun','swiftc','-O',HERE/'TestKey.swift','-o',OUTPUT/'make-test-key'])
        public = run([OUTPUT/'make-test-key',key],capture_output=True).stdout.strip()
        (OUTPUT/'test-public-key.txt').write_text(public+'\n')
    print('PASS: compiled probe and signed arm64 Sparkle framework',flush=True)

class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_): pass

def rows(root):
    path=root/'events.jsonl'
    if not path.exists(): return []
    result=[]
    for line in path.read_text().splitlines():
        try: result.append(json.loads(line))
        except json.JSONDecodeError: pass
    return result

def bundle(path, version, identifier, scenario, root, feed):
    if REAL:
        shutil.copytree(Path('/private/tmp/OKVideoMac-SparkleStage2-Real/Template.app'),path,symlinks=True)
        info=plistlib.loads((path/'Contents/Info.plist').read_bytes())
    else:
        (path/'Contents/MacOS').mkdir(parents=True)
        (path/'Contents/Frameworks').mkdir()
        shutil.copy2(OUTPUT/'UpdateProbe',executable(path))
        shutil.copytree(OUTPUT/'Sparkle.framework',path/'Contents/Frameworks/Sparkle.framework',symlinks=True)
        info={}
    info.update({'CFBundleExecutable':executable(path).name,'CFBundleIdentifier':identifier,
          'CFBundleName':'UpdateProbe','CFBundleDisplayName':'OKVideoMac Update Probe',
          'CFBundlePackageType':'APPL','CFBundleVersion':str(version),'CFBundleShortVersionString':f'0.0.{version}',
          'NSPrincipalClass':'NSApplication','LSMinimumSystemVersion':'12.0',
          'SUFeedURL':feed,'SUPublicEDKey':(OUTPUT/'test-public-key.txt').read_text().strip(),
          'SUAutomaticallyUpdate':False,'SUAllowsAutomaticUpdates':False,
          'SUScheduledCheckInterval':86400,'SUEnableSystemProfiling':False,
          'SUVerifyUpdateBeforeExtraction':True,'SURequireSignedFeed':True,
          'SUSignedFeedFailureExpirationInterval':0,
          # Loopback transport is confined to this disposable probe. Signatures remain required.
          'NSAppTransportSecurity':{'NSAllowsLocalNetworking':True,'NSAllowsArbitraryLoads':True},
          'OKUpdateProbeRoot':str(root),'OKUpdateProbeScenario':scenario})
    (path/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    sign(path)
    run(['codesign','--verify','--deep','--strict',path])

def case(scenario):
    root=OUTPUT/(('real-' if REAL else '')+scenario+'-'+uuid.uuid4().hex[:8])
    root.mkdir(mode=0o700)
    if REAL:
        with wave.open(str(root/'silent.wav'),'wb') as wav:
            wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(48000)
            wav.writeframes(b'\0\0'*48000*120)
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(Handler,directory=str(root)))
    threading.Thread(target=server.serve_forever,daemon=True).start()
    url=f'http://127.0.0.1:{server.server_port}'
    identifier='com.okvideomac.sparkleprobe.'+uuid.uuid4().hex
    installed=root/'Installed/UpdateProbe.app'
    next_app=root/'Next/UpdateProbe.app'
    result={'scenario':scenario,'real_app':REAL,'root':str(root),'bundle_id':identifier,
            'transport':'loopback HTTP fixture only; production HTTPS not tested',
            'signing':'Developer ID; not notarized; disposable test-only bundles'}
    try:
        bundle(installed,1,identifier,scenario,root,url+'/appcast.xml')
        bundle(next_app,2,identifier,scenario,root,url+'/appcast.xml')
        old_hash=sha(executable(installed))
        run(['hdiutil','create','-quiet','-volname','OKVideoMac Update Probe','-srcfolder',next_app.parent,
             '-fs','HFS+','-format','UDZO',root/'update.dmg'])
        sign(root/'update.dmg')
        signer=DEPENDENCIES/'bin/sign_update'
        attributes=run([signer,'--ed-key-file',OUTPUT/'test-private-key.txt',root/'update.dmg'],capture_output=True).stdout.strip()
        # The signed enclosure binds the final DMG bytes; no mutations follow.
        enclosure=ET.fromstring('<enclosure xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" '+attributes+'/>')
        signature=enclosure.attrib['{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature']
        feed=f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Isolated Update Probe</title><item><title>Probe 2</title><sparkle:version>2</sparkle:version><sparkle:shortVersionString>0.0.2</sparkle:shortVersionString><sparkle:minimumSystemVersion>12.0</sparkle:minimumSystemVersion><enclosure url="{url}/update.dmg" length="{(root/'update.dmg').stat().st_size}" type="application/octet-stream" sparkle:edSignature="{signature}"/></item></channel></rss>
'''
        (root/'appcast.xml').write_text(feed)
        run([signer,'--ed-key-file',OUTPUT/'test-private-key.txt',root/'appcast.xml'],capture_output=True)
        run([signer,'--verify','--ed-key-file',OUTPUT/'test-private-key.txt',root/'appcast.xml'],capture_output=True)
        if scenario=='tampered-feed':
            (root/'appcast.xml').write_text((root/'appcast.xml').read_text().replace('Probe 2','Tampered Probe 2'))
        if scenario=='tampered-archive':
            with (root/'update.dmg').open('r+b') as dmg:
                dmg.seek(64); original=dmg.read(1); dmg.seek(64)
                dmg.write(bytes([original[0]^1]))
        run(['open','-n',installed])
        end=time.monotonic()+90
        expected_negative={'cancel-download':'download_cancelled','cancel-install':'install_cancelled','tampered-feed':'update_error','tampered-archive':'update_error'}
        while time.monotonic()<end:
            events=rows(root)
            if REAL and 'loaded_libmpv' not in result:
                launched=next((r for r in events if r['event']=='launched' and r['version']=='1'),None)
                if launched:
                    maps=run(['lsof','-p',str(launched['pid']),'-Fn'],capture_output=True).stdout.splitlines()
                    loaded=sorted(set(line[1:] for line in maps if line.startswith('n') and line.endswith('/libmpv.dylib')))
                    assert loaded==[str(installed/'Contents/Frameworks/libmpv.dylib')],loaded
                    result['loaded_libmpv']=loaded[0]
            if scenario in expected_negative:
                if any(r['event']==expected_negative[scenario] for r in events):
                    time.sleep(2)
                    version=plistlib.loads((installed/'Contents/Info.plist').read_bytes())['CFBundleVersion']
                    assert version=='1'
                    assert sha(executable(installed))==old_hash
                    if scenario=='tampered-feed':
                        assert any(r['event']=='update_error' and 'Code=3002' in r.get('error','') for r in events)
                        assert not any(r['event']=='download_started' for r in events)
                    if scenario=='tampered-archive':
                        assert any(r['event']=='update_error' and 'Code=4005' in r.get('error','')
                                   and 'Code=3002' in r.get('error','')
                                   and 'signature validation before unarchiving failed' in r.get('error','') for r in events)
                        assert not any(r['event']=='ready_to_install' for r in events)
                    pid=next(r['pid'] for r in events if r['event']=='launched' and r['version']=='1')
                    os.kill(pid,0)
                    result.update(outcome='PASS',old_app_preserved=True,old_process_alive=True)
                    if scenario=='cancel-install':
                        run(['osascript','-e',f'tell application id "{identifier}" to quit'],capture_output=True)
                        quit_end=time.monotonic()+15
                        while time.monotonic()<quit_end:
                            try: os.kill(pid,0)
                            except ProcessLookupError: break
                            time.sleep(0.2)
                        else: raise TimeoutError('Cancelled fixture did not quit')
                        time.sleep(3)
                        assert plistlib.loads((installed/'Contents/Info.plist').read_bytes())['CFBundleVersion']=='1'
                        assert not any(r['version']=='2' for r in rows(root))
                        result.update(no_install_on_later_quit=True)
                    break
            elif any(r['event']=='new_version_verified' for r in events):
                old=[r for r in events if r['version']=='1']
                new=[r for r in events if r['event']=='new_version_verified']
                assert len(new)==1
                assert len([r for r in old if r['event']=='termination_replied'])==1
                assert len([r for r in old if r['event']=='cleanup_started'])==1
                if scenario=='cancel-termination-once':
                    assert len([r for r in old if r['event']=='termination_cancelled_once'])==1
                    assert any(r['event']=='retry_termination' for r in old)
                if scenario=='timeout':
                    assert any(r['event']=='cleanup_timeout' for r in old)
                    assert not any(r['event']=='cleanup_completed' for r in old)
                else:
                    assert any(r['event']=='cleanup_completed' for r in old)
                    assert not any(r['event']=='cleanup_timeout' for r in old)
                    if REAL:
                        for marker in ('restart_exclusion_verified','history_flushed','player_shutdown_completed',
                                       'node_shutdown_completed','android_shutdown_completed'):
                            assert len([r for r in old if r['event']==marker])==1,marker
                        assert next(r for r in old if r['event']=='player_shutdown_completed')['nativeReleased']
                        if scenario=='idle': assert new[0]['historyCount']==0
                        else:
                            assert new[0]['historyCount']==1 and new[0]['savedPosition']>=17.5
                            playback=next(r for r in old if r['event']=='real_playback_verified')
                            assert new[0]['savedPosition']>=playback['position']-0.2
                        result['saved_position']=new[0]['savedPosition']
                    else: assert new[0]['savedProgress']=='position=17.5'
                old_pid=old[0]['pid']
                try: os.kill(old_pid,0)
                except ProcessLookupError: pass
                else: raise AssertionError('Old process is still alive after new version launch')
                assert max(r['uptime'] for r in old if r['event']=='will_terminate') < new[0]['uptime']
                run(['codesign','--verify','--deep','--strict',installed])
                result.update(outcome='PASS' if scenario!='timeout' else 'EXPECTED_TIMEOUT',
                              new_version='2',old_process_exited=True,new_launch_count=len(new))
                break
            elif any(r['event'] in ('update_error','updater_start_failed','fixture_failed') for r in events):
                raise RuntimeError(json.dumps(events[-5:]))
            time.sleep(0.2)
        else:
            raise TimeoutError(json.dumps(rows(root)[-10:]))
    except Exception as error:
        result.update(outcome='FAIL',error=str(error))
        raise
    finally:
        (root/'result.json').write_text(json.dumps(result,indent=2)+'\n')
        # Stop only fixture PIDs still associated with this unique fixture executable.
        time.sleep(2)
        for pid in {r['pid'] for r in rows(root)}:
            status=subprocess.run(['ps','-p',str(pid),'-o','command='],capture_output=True,text=True)
            if status.stdout.strip()==str(executable(installed)):
                try: os.kill(pid,signal.SIGTERM)
                except ProcessLookupError: pass
        server.shutdown();server.server_close()
    print(json.dumps(result),flush=True)
    return result

def main():
    global REAL
    parser=argparse.ArgumentParser()
    parser.add_argument('mode',choices=['prepare','mini','real'])
    parser.add_argument('--case',default='normal',choices=['normal','idle','playing','paused','timeout','cancel-termination-once','cancel-download','cancel-install','tampered-feed','tampered-archive'])
    args=parser.parse_args()
    REAL=args.mode=='real'
    if REAL: assert args.case in ('idle','playing','paused')
    else: assert args.case not in ('idle','playing','paused')
    if args.mode=='prepare': prepare()
    else: case(args.case)

if __name__=='__main__': main()
