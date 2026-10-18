#!/usr/bin/env python3
"""Offline process-lifecycle tests; no actual Mac app or network is used."""
from pathlib import Path
import json, os, pty, shutil, signal, subprocess, sys, tempfile, time, unittest

ROOT=Path(__file__).resolve().parents[1]
MOCK=r'''
import json, os, sys, signal, stat
from pathlib import Path
name=Path(sys.argv[0]).name; args=sys.argv[1:]; scenario=os.environ['MOCK_SCENARIO']
state=Path(os.environ['MOCK_APP_STATE'])
if name=='uname': print('Darwin')
elif name=='id': print('501')
elif name=='stat':
    value=os.stat(args[-1]); print('501' if args[1]=='%u' else format(stat.S_IMODE(value.st_mode),'o'))
elif name=='codesign':
    assert '--verify' in args and '--strict' in args and '-R' in args
    assert '2DC432GLL2' in args[args.index('-R')+1]
    sys.exit(1 if scenario=='bad_signature' else 0)
elif name=='PlistBuddy':
    key=args[1].split(':')[-1]
    print({'CFBundleIdentifier':'com.other.app' if scenario=='wrong_app' else 'com.openai.codex','CFBundleExecutable':'Codex','CFBundleShortVersionString':'39.0.0' if 'Electron' in args[-1] else '26.1007.30912'}[key])
elif name=='nc':
    assert args[-2:]==['127.0.0.1','7897']; sys.exit(1 if scenario=='no_port' else 0)
elif name=='osascript':
    action,path=args[3:5]; assert action in ['status','quit']
    if scenario=='status_failed': sys.exit(1)
    if state.exists():
        data=json.loads(state.read_text())
        if data['app']!=path: sys.exit(1)
        if action=='status': print(data['pid'])
        elif scenario=='quit_refused' or args[5]!=str(data['pid']): sys.exit(1)
        else: os.kill(data['pid'],signal.SIGTERM)
elif name=='open':
    assert args[0]=='-a' and len(args)==2
    Path(os.environ['MOCK_OPEN_LOG']).write_text(json.dumps({'app':args[1],'HTTP_PROXY':os.environ.get('HTTP_PROXY'),'NODE_OPTIONS':os.environ.get('NODE_OPTIONS')}))
else: raise AssertionError(name)
'''
FAKE_APP=r'''
import os,sys,json,signal,time
from pathlib import Path
state=Path(os.environ['MOCK_APP_STATE'])
app=str(Path(__file__).resolve().parents[2])
data={'pid':os.getpid(),'app':app,'args':sys.argv[1:],'env':{k:os.environ.get(k) for k in ['HTTP_PROXY','HTTPS_PROXY','http_proxy','https_proxy','ALL_PROXY','all_proxy','NO_PROXY','NODE_OPTIONS','NODE_TLS_REJECT_UNAUTHORIZED']}}
state.write_text(json.dumps(data))
def close(*_):
    try:
        if json.loads(state.read_text())['pid']==os.getpid(): state.unlink()
    except (OSError,ValueError): pass
    sys.exit(0)
signal.signal(signal.SIGTERM,close)
for _ in range(1200): time.sleep(.05)
close()
'''

class LaunchTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='proxy launch 中文 ')
        self.root=Path(self.tmp.name); self.home=self.root/'home'; self.home.mkdir()
        self.bin=self.root/'bin'; self.bin.mkdir()
        self.app=self.home/'Applications/Codex.app'
        for d in ['Contents/MacOS','Contents/Frameworks/Electron Framework.framework/Resources']:
            (self.app/d).mkdir(parents=True)
        (self.app/'Contents/Info.plist').write_text('metadata fixture')
        (self.app/'Contents/Frameworks/Electron Framework.framework/Resources/Info.plist').write_text('framework fixture')
        self.binary=self.app/'Contents/MacOS/Codex'
        self.binary.write_text('#!'+sys.executable+'\n'+FAKE_APP); self.binary.chmod(0o700)
        self.state=self.root/'app.json'; self.openlog=self.root/'open.json'
        self.env=dict(os.environ,HOME=str(self.home),MOCK_SCENARIO='ok',MOCK_APP_STATE=str(self.state),MOCK_OPEN_LOG=str(self.openlog),HTTP_PROXY='http://original.invalid:1234',NODE_OPTIONS='original-marker')
        for name in ['uname','id','stat','codesign','PlistBuddy','nc','osascript','open']:
            f=self.bin/name; f.write_text('#!'+sys.executable+'\n'+MOCK); f.chmod(0o700)
        s=(ROOT/'try-codex-proxy.command').read_text()
        s=s.replace('PATH=/usr/bin:/bin:/usr/sbin:/sbin',f'PATH="{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin"').replace('/usr/libexec/PlistBuddy','"'+str(self.bin/'PlistBuddy')+'"')
        self.script=self.root/'try-codex-proxy.command'; self.script.write_text(s)
        shutil.copy2(ROOT/'restore-codex-proxy.command',self.root/'restore-codex-proxy.command')
        (self.root/'lib').mkdir(); shutil.copy2(ROOT/'lib/mac-app-control.js',self.root/'lib/mac-app-control.js')
        self.session=self.home/'Library/Application Support/mac-network-config/desktop-proxy-test/active'
        config=self.home/'.codex'; config.mkdir()
        (config/'config.toml').write_text('SECRET_CONFIG=not_read\n')
        (config/'.env').write_text('SECRET_PASSWORD=not_read\n')
        self.original_config={p.name:p.read_bytes() for p in config.iterdir()}

    def tearDown(self):
        if self.state.exists():
            try: os.kill(json.loads(self.state.read_text())['pid'],signal.SIGTERM)
            except (OSError,ValueError): pass
            time.sleep(.1)
        self.assertEqual({p.name:p.read_bytes() for p in (self.home/'.codex').iterdir()},self.original_config)
        self.tmp.cleanup()

    def run_tool(self,answers='TEST\nFAIL\n',restore=False):
        master,slave=pty.openpty()
        entry=self.root/('restore-codex-proxy.command' if restore else 'try-codex-proxy.command')
        p=subprocess.Popen(['bash',str(entry)],env=self.env,stdin=slave,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        os.close(slave)
        try:
            os.write(master,answers.encode())
            out,err=p.communicate(timeout=30)
        finally: os.close(master)
        self.assertNotIn('SECRET_',out+err)
        return p.returncode,out,err

    def test_launch_restore_and_original_environment(self):
        old=subprocess.Popen([str(self.binary)],env=self.env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        for _ in range(100):
            if self.state.exists(): break
            time.sleep(.01)
        code,out,err=self.run_tool(); self.assertEqual(code,0,out+err)
        old.wait(timeout=4)
        data=json.loads(self.state.read_text())
        self.assertIn('--proxy-server=http://127.0.0.1:7897',data['args'])
        for k in ['HTTP_PROXY','HTTPS_PROXY','http_proxy','https_proxy']:
            self.assertEqual(data['env'][k],'http://127.0.0.1:7897')
        for k in ['ALL_PROXY','all_proxy','NODE_OPTIONS','NODE_TLS_REJECT_UNAUTHORIZED']:
            self.assertIsNone(data['env'][k])
        self.assertEqual(data['env']['NO_PROXY'],'localhost,127.0.0.1,::1')
        for f in self.session.iterdir(): self.assertEqual(f.stat().st_mode & 0o077,0)
        code,out,err=self.run_tool('RESTORE\n',True); self.assertEqual(code,0,out+err)
        self.assertFalse(self.session.exists()); self.assertFalse(self.state.exists())
        original=json.loads(self.openlog.read_text())
        self.assertEqual(original['HTTP_PROXY'],'http://original.invalid:1234')
        self.assertEqual(original['NODE_OPTIONS'],'original-marker')

    def test_originally_closed_app_stays_closed_after_restore(self):
        self.assertEqual(self.run_tool()[0],0)
        code,out,err=self.run_tool('RESTORE\n',True)
        self.assertEqual(code,0,out+err)
        self.assertFalse(self.state.exists()); self.assertFalse(self.openlog.exists())
        self.assertFalse(self.session.exists())

    def test_cancel_does_not_write_or_launch(self):
        code,out,err=self.run_tool('NO\n'); self.assertEqual(code,0,out+err)
        self.assertFalse(self.session.exists()); self.assertFalse(self.state.exists())

    def test_bad_preconditions_do_not_launch(self):
        for scenario in ['bad_signature','wrong_app','no_port','status_failed']:
            with self.subTest(scenario=scenario):
                self.env['MOCK_SCENARIO']=scenario
                code,out,err=self.run_tool(); self.assertNotEqual(code,0,out+err)
                self.assertFalse(self.session.exists()); self.assertFalse(self.state.exists())

    def test_missing_electron_is_refused(self):
        shutil.rmtree(self.app/'Contents/Frameworks')
        code,out,err=self.run_tool(); self.assertNotEqual(code,0,out+err)
        self.assertFalse(self.session.exists()); self.assertFalse(self.state.exists())

    def test_existing_app_graceful_restart(self):
        old=subprocess.Popen([str(self.binary)],env=self.env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        for _ in range(100):
            if self.state.exists(): break
            time.sleep(.01)
        code,out,err=self.run_tool(); self.assertEqual(code,0,out+err)
        old.wait(timeout=4)
        self.assertNotEqual(json.loads(self.state.read_text())['pid'],old.pid)
        code,out,err=self.run_tool('RESTORE\n',True); self.assertEqual(code,0,out+err)

    def test_cancel_restore_preserves_test(self):
        self.assertEqual(self.run_tool()[0],0)
        pid=json.loads(self.state.read_text())['pid']
        self.assertEqual(self.run_tool('NO\n',True)[0],0)
        self.assertEqual(json.loads(self.state.read_text())['pid'],pid)
        self.assertTrue(self.session.exists()); self.assertFalse(self.openlog.exists())

    def test_quit_refusal_never_force_kills(self):
        old=subprocess.Popen([str(self.binary)],env=self.env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        for _ in range(100):
            if self.state.exists(): break
            time.sleep(.01)
        self.env['MOCK_SCENARIO']='quit_refused'
        code,out,err=self.run_tool()
        self.assertNotEqual(code,0); self.assertIsNone(old.poll())
        self.assertEqual(json.loads(self.state.read_text())['pid'],old.pid)
        self.assertFalse((self.session/'test-pid').exists())
        self.env['MOCK_SCENARIO']='ok'
        code,out,err=self.run_tool('RESTORE\n',True)
        self.assertEqual(code,0,out+err); self.assertIsNone(old.poll())
        os.kill(old.pid,signal.SIGTERM); old.wait(timeout=3)

    def test_noninteractive_execution_is_refused(self):
        p=subprocess.run(['bash',str(self.script)],env=self.env,input='TEST\nFAIL\n',text=True,capture_output=True)
        self.assertNotEqual(p.returncode,0); self.assertIn('需要交互式',p.stderr)
        self.assertFalse(self.session.exists()); self.assertFalse(self.state.exists())

    def test_changed_app_is_not_controlled(self):
        self.assertEqual(self.run_tool()[0],0)
        with self.binary.open('a') as f: f.write('\n# newer version\n')
        code,out,err=self.run_tool('RESTORE\n',True)
        self.assertNotEqual(code,0); self.assertIn('应用已更新',out+err)
        self.assertTrue(self.state.exists()); self.assertFalse(self.openlog.exists())

    def test_pid_reuse_does_not_quit_current_instance(self):
        self.assertEqual(self.run_tool()[0],0)
        (self.session/'pid-start').write_text('a different process start')
        pid=json.loads(self.state.read_text())['pid']
        code,out,err=self.run_tool('RESTORE\n',True); self.assertEqual(code,0,out+err)
        self.assertEqual(json.loads(self.state.read_text())['pid'],pid)
        self.assertFalse(self.openlog.exists())

    def test_second_test_is_refused(self):
        self.assertEqual(self.run_tool()[0],0)
        code,out,err=self.run_tool(); self.assertNotEqual(code,0)
        self.assertIn('已有启动记录',out+err)

    def test_no_session_restore_is_noop(self):
        code,out,err=self.run_tool('RESTORE\n',True)
        self.assertEqual(code,0,out+err); self.assertFalse(self.openlog.exists())


class GuardTests(unittest.TestCase):
    def test_syntax_and_guard(self):
        for name in ['try-codex-proxy.command','restore-codex-proxy.command']:
            subprocess.run(['bash','-n',str(ROOT/name)],check=True)
        p=subprocess.run(['bash',str(ROOT/'try-codex-proxy.command'),'--help'],capture_output=True,text=True)
        self.assertEqual(p.returncode,0)
        if sys.platform!='darwin':
            p=subprocess.run(['bash',str(ROOT/'try-codex-proxy.command')],capture_output=True,text=True)
            self.assertEqual(p.returncode,1); self.assertIn('Mac 本机',p.stderr)

    def test_jxa_syntax_and_runtime_api(self):
        node=shutil.which('node')
        if not node: self.skipTest('Node not installed (developer-only optional check)')
        source=(ROOT/'lib/mac-app-control.js').read_text()
        harness=r'''const fs=require('fs'),vm=require('vm');
const code=fs.readFileSync(process.argv[1],'utf8');
let terminated=false;
const app={bundleIdentifier:'com.openai.codex',bundleURL:{path:'/a.app'},processIdentifier:123,get terminate(){terminated=true;return true;}};
const context={ObjC:{import(){},unwrap(x){return x;}},$:{NSWorkspace:{sharedWorkspace:{runningApplications:{js:[app]}}}}};
vm.createContext(context);vm.runInContext(code,context);
if(context.run(['status','/a.app'])!=='123')throw Error('status');
if(context.run(['quit','/a.app','123'])!=='requested'||!terminated)throw Error('quit');
let refused=false;try{context.run(['quit','/other.app','123']);}catch(e){refused=true;}if(!refused)throw Error('wrong target');
terminated=false;refused=false;try{context.run(['quit','/a.app','456']);}catch(e){refused=true;}if(!refused||terminated)throw Error('changed pid');
'''
        subprocess.run([node,'-e',harness,str(ROOT/'lib/mac-app-control.js')],check=True)

if __name__=='__main__': unittest.main(verbosity=2)
