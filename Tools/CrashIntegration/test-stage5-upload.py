"""Actual formal App transport and UI, using only synthetic reports and a local HTTP sink."""
import gzip, http.server, json, os, plistlib, resource, shutil, subprocess, tempfile, threading, time
from pathlib import Path
ROOT=Path('/private/tmp/OKVideoMac-CrashIntegration')
APP=Path(tempfile.mkdtemp(prefix='Stage5-',dir=ROOT))/'OKVideoMac.app'
EXE=APP/'Contents/MacOS/OKVideoMac';UI=ROOT/'owned-ui-probe'
ID='com.okvideomac.OKVideoMac.acceptance8b3b'
cases=[];owned=[]
def wait(f,timeout=20):
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        v=f()
        if v:return v
        time.sleep(.03)
    raise AssertionError('Timed out')
def no_core():resource.setrlimit(resource.RLIMIT_CORE,(0,0))
def workspace():return Path(tempfile.mkdtemp(prefix='OKVideoMac-8B3B-upload-',dir='/private/tmp'))
def env(root):
    e=os.environ.copy();e.pop('XCTestBundlePath',None);e.pop('XCTestConfigurationFilePath',None);e['OKVIDEOMAC_8B3B_ROOT']=str(root);return e
def call(root,*args,timeout=15):
    p=subprocess.run([str(EXE),*args],env=env(root),capture_output=True,text=True,timeout=timeout,preexec_fn=no_core)
    assert p.returncode==0,(args,p.returncode,p.stdout[-200:],p.stderr[-400:])
    return json.loads(p.stdout.strip().splitlines()[-1])
def report_root(root):return root/'Application Support/Diagnostics/CrashReports'
def pending(root):return list((report_root(root)/'pending').glob('*.json'))
def database(root):return root/'Application Support/Database/OKVideoMac.sqlite3'
def make_report(root,kind='swift'):
    p=subprocess.run([str(EXE),'--diagnostic-crash-stage','entry','--diagnostic-crash-kind',kind],env=env(root),capture_output=True,timeout=15,preexec_fn=no_core)
    assert p.returncode<0
    return call(root,'--diagnostic-export')['reports'][0]
def passed(name,**kwargs):cases.append({'name':name,'status':'PASS',**kwargs});print('PASS:',name,flush=True)
class Sink:
    def __init__(self,status=200,delay=0):
        self.requests=[];self.status=status;self.delay=delay;parent=self
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                data=self.rfile.read(int(self.headers['Content-Length']))
                if self.headers.get('Content-Encoding')=='gzip':data=gzip.decompress(data)
                parent.requests.append(data);time.sleep(parent.delay)
                self.send_response(parent.status);self.end_headers()
                try:self.wfile.write(b'{}')
                except (BrokenPipeError,ConnectionResetError):pass
            def log_message(self,*a):pass
        self.server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start()
        self.dsn=f'http://public@127.0.0.1:{self.server.server_port}/1'
    def close(self):self.server.shutdown();self.server.server_close()
    def events(self):
        events=[]
        for packet in self.requests:
            lines=packet.splitlines();assert len(lines)==3
            assert json.loads(lines[1])['type']=='event';events.append(json.loads(lines[2]))
        return events
def snapshot(p):return json.loads(subprocess.check_output([str(UI),'snapshot',str(p.pid)],text=True))
def element(p,id):return next((r for r in snapshot(p) if r.get('AXIdentifier')==id),None)
def windows(p):return int(subprocess.check_output([str(ROOT/'window-probe'),str(p.pid)],text=True))
def press(p,id):subprocess.run([str(UI),'press',str(p.pid),id],check=True)
def launch(root,sink,fault=None):
    args=[str(EXE),'--diagnostic-test-dsn',sink.dsn]
    if fault:args+=['--diagnostic-worker-fault',fault]
    logfile=ROOT/f'logs/stage5-ui-{len(owned)}.log';log=logfile.open('wb')
    p=subprocess.Popen(args,env=env(root),stdout=log,stderr=log);owned.append((p,log,logfile));wait(lambda:windows(p)==1);return p

def children(pid):
    result=subprocess.run(['pgrep','-P',str(pid)],capture_output=True,text=True)
    return [int(p) for p in result.stdout.split()]
def alive(pid):
    try:os.kill(pid,0);return True
    except ProcessLookupError:return False

def quit(p):subprocess.run([str(ROOT/'instance-probe'),'quit',str(p.pid)],check=True);p.wait(timeout=12)

shutil.copytree(ROOT/'DerivedData/Build/Products/Release/OKVideoMac.app',APP,symlinks=True)
info=APP/'Contents/Info.plist';data=plistlib.loads(info.read_bytes());data['CFBundleIdentifier']=ID;info.write_bytes(plistlib.dumps(data))
fixture=APP/'Contents/Frameworks/libCrashAcceptanceFixture.dylib'
subprocess.run(['xcrun','clang','-arch','arm64','-mmacosx-version-min=12.0','-dynamiclib','-O2','-g','-fno-omit-frame-pointer','-install_name','@rpath/libCrashAcceptanceFixture.dylib','Tools/CrashIntegration/CrashFixture.c','-o',str(fixture)],check=True)
subprocess.run(['python3','OKVideoMac/macOS/OKVideoMac/Scripts/crash-image-metadata.py',str(APP)],check=True)
subprocess.run(['codesign','--force','--sign','-','--options','runtime',str(fixture)],check=True,capture_output=True)
subprocess.run(['codesign','--force','--sign','-','--options','runtime','--entitlements','OKVideoMac/macOS/OKVideoMac/Supporting/OKVideoMac.dev.entitlements',str(APP)],check=True,capture_output=True)
subprocess.run(['codesign','--verify','--strict',str(APP)],check=True)
sinks=[]
def sink(**kwargs):s=Sink(**kwargs);sinks.append(s);return s
try:
    s=sink();root=workspace();record=make_report(root)
    for _ in range(2):
        r=call(root,'--diagnostic-upload-model','--diagnostic-test-dsn',s.dsn)
        assert not r['consent'] and r['pending']==1 and not r['businessInitialized'] and not r['cacheExists']
    assert not s.requests;passed('no consent means no SDK request and no business bootstrap')
    r=call(root,'--diagnostic-upload-model','--diagnostic-grant','--diagnostic-test-dsn',s.dsn)
    assert r['pending']==0 and r['consent'] and not r['cacheExists']
    event=s.events()[0]
    assert event['event_id']==record['id'] and event['release']=='com.okvideomac.OKVideoMac@0.8.4+137'
    assert event['environment']=='okvideomac-crash-integration-acceptance' and event['dist']=='137'
    assert set(event)=={'contexts','debug_meta','dist','environment','event_id','exception','level','platform','release','threads','timestamp','breadcrumbs'}
    assert set(event['contexts'])=={'os','device','crash_diagnostics','last_operation'}
    assert event['contexts']['crash_diagnostics']['first_throw_stack_available'] is False
    assert all(b['category']=='app.operation' for b in event['breadcrumbs'])
    assert not {'user','request','logentry'} & set(event)
    for bad in [b'DO_NOT_SEND',b'/Users/',b'example.invalid',b'token=secret']:
        assert bad not in s.requests[0],bad
    exception=event['exception']['values'][0];crashed=next(t for t in event['threads']['values'] if t['crashed'])
    assert exception['stacktrace']==crashed['stacktrace'];assert any(f['in_app'] for f in exception['stacktrace']['frames'])
    call(root,'--diagnostic-upload-model','--diagnostic-test-dsn',s.dsn);assert len(s.requests)==1
    passed('grant sends a single actual allowlisted SDK event with formal App identity')
    root=workspace();make_report(root);r=call(root,'--diagnostic-upload-model','--diagnostic-grant')
    assert r['pending']==1 and r['status']=='unconfigured' and r['consent'];assert not database(root).exists()
    call(root,'--diagnostic-upload-model','--diagnostic-revoke');assert not pending(root)
    passed('missing DSN allows local capture and preference changes without sending')
    fail=sink(status=503);root=workspace();record=make_report(root)
    for _ in range(2):
        r=call(root,'--diagnostic-upload-model','--diagnostic-grant','--diagnostic-test-dsn',fail.dsn)
        assert r['pending']==1 and r['status']=='pending' and not r['cacheExists']
    assert [e['event_id'] for e in fail.events()]==[record['id']]*2
    success=sink();r=call(root,'--diagnostic-upload-model','--diagnostic-test-dsn',success.dsn)
    assert r['pending']==0 and success.events()[0]['event_id']==record['id']
    passed('503 keeps the same event ID for retry; only an HTTP receipt removes the record')
    root=workspace();make_report(root);r=call(root,'--diagnostic-upload-model','--diagnostic-grant','--diagnostic-test-dsn','http://public@127.0.0.1:1/1')
    assert r['pending']==1 and not r['cacheExists'];passed('refused connection preserves report and removes SDK cache')
    for fault in ['spawnFailure','exitBeforeRead','exitAfterRead','invalidReply','oversizedReply','noRead','noReply']:
        root=workspace();make_report(root)
        r=call(root,'--diagnostic-upload-probe','--worker-fault',fault)
        assert r['outcomes']==['pending'] and r['pending']==1 and r['callbacks']==1
        assert not r['cacheExists'] and r['maxMainGap']<.5 and r['seconds']<9.5
        if fault in ['noRead','noReply']:assert r['seconds']>=8 and r['ticks']>100
        passed('real upload worker fault: '+fault,seconds=r['seconds'],max_main_gap=r['maxMainGap'])
    root=workspace();record=make_report(root);path=pending(root)[0]
    frame={'pc':18446744073709550000,'imageBase':18446744073709500000}
    def encode(count):
        record['threads']=[{'number':n,'crashed':n==0,'frames':[frame]*min(256,count-n*256)} for n in range((count+255)//256)]
        return json.dumps(record,separators=(',',':')).encode()
    low,high=1,128*256
    while low<high:
        mid=(low+high+1)//2
        if len(encode(mid))<=1_040_000:low=mid
        else:high=mid-1
    path.write_bytes(encode(low));assert path.stat().st_size>1_000_000
    r=call(root,'--diagnostic-upload-probe','--worker-fault','noRead')
    assert r['outcomes']==['pending'] and r['pending']==1 and r['seconds']>=8 and r['maxMainGap']<.5
    passed('full nonreading pipe obeys eight-second deadline without blocking main runloop',bytes=path.stat().st_size,max_main_gap=r['maxMainGap'])
    r=call(root,'--diagnostic-upload-probe','--worker-fault','noRead','--revoke-after','0.15')
    assert r['outcomes']==['revoked'] and not r['consent'] and r['pending']==0 and not r['cacheExists'] and r['seconds']<1
    passed('revocation cancels/reaps the active worker and clears reports before completion')
    root=workspace();make_report(root);r=call(root,'--diagnostic-upload-probe','--worker-fault','exitAfterRead','--attempts','20')
    assert r['callbacks']==20 and r['outcomes']==['pending']*20 and r['fds'][-1]<=r['fds'][0]+1
    passed('twenty real workers do not accumulate file descriptors')
    # End-to-end recovery and settings share the same model.
    slow=sink(delay=3);root=workspace();make_report(root);p=launch(root,slow)
    wait(lambda:element(p,'crash-recovery-continue'));toggle=element(p,'crash-upload-consent')
    assert toggle and toggle.get('AXValue')==0 and not slow.requests
    press(p,'crash-upload-consent');wait(lambda:len(slow.requests)==1)
    assert not database(root).exists() and windows(p)==1
    press(p,'crash-recovery-continue');wait(lambda:database(root).exists())
    assert windows(p)==1;subprocess.run([str(UI),'keys',str(p.pid),'43'],check=True);wait(lambda:windows(p)==2)
    # Settings defaults to a different section; use its Advanced button before inspecting the shared control.
    rows=snapshot(p);(ROOT/'logs/stage5-settings-snapshot.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2))
    if not element(p,'crash-upload-consent'):
        titles=[r.get('AXTitle') or r.get('AXDescription') for r in rows if r.get('AXRole')=='AXButton'];print('Settings buttons:',titles,flush=True)
        advanced=next((v for v in titles if v and any(part in v for part in ['Advanced','高级','進階'])),None);assert advanced
        press(p,advanced)
    wait(lambda:element(p,'crash-upload-consent'))
    assert element(p,'crash-upload-consent')['AXValue']==1
    press(p,'crash-upload-consent');wait(lambda:json.loads((report_root(root)/'consent.json').read_text()) is False)
    wait(lambda:not pending(root) and not (report_root(root)/'sentry-cache').exists() and not children(p.pid))
    assert owned[-1][2].read_text(errors='replace').count('create client')==1
    subprocess.run([str(UI),'capture',str(p.pid),str(ROOT/'stage5-settings.png'),'front'],check=True)
    quit(p);passed('actual recovery and settings toggles share consent; Continue remains responsive during sending')
    # A killed parent cannot leave either a reading or nonreading worker behind.
    for fault in ['noRead','none']:
        root=workspace();make_report(root)
        args=[str(EXE),'--diagnostic-upload-probe','--worker-fault',fault,'--test-dsn',slow.dsn]
        p=subprocess.Popen(args,env=env(root),stdout=subprocess.PIPE,stderr=subprocess.PIPE);owned.append((p,None,None))
        child=wait(lambda:children(p.pid));assert len(child)==1;time.sleep(.15);p.kill();p.communicate(timeout=3)
        wait(lambda:not any(alive(c) for c in child),timeout=3)
        call(root,'--diagnostic-export');assert not (report_root(root)/'sentry-cache').exists()
    passed('parent exit retires both worker phases; next launch clears abandoned cache')
    result={'status':'PASS','cases':cases,'app_path':str(APP),'scope':'synthetic formal App crashes and actual SDK HTTP payloads; no external Sentry data','screenshots':['stage5-settings.png']}
    (ROOT/'stage5-upload.json').write_text(json.dumps(result,indent=2)+'\n')
finally:
    for p,log,_ in owned:
        if p.poll() is None:p.terminate();p.wait(timeout=5)
        if log:log.close()
    for s in sinks:s.close()
