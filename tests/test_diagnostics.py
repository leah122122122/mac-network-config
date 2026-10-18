#!/usr/bin/env python3
"""Offline tests. Production code has no mock/test switch. No network requests."""
from pathlib import Path
import base64
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'diagnose-macos.sh').read_text()


def awk_response(text, expected='test-accept'):
    p = subprocess.run(['awk', '-v', 'expected=' + expected, '-f', str(ROOT/'lib/response.awk')],
                       input=text, text=True, capture_output=True, check=True)
    return p.stdout.strip().split()


def response(status='101', accept='test-accept', metrics='101', headers=True):
    text = 'HTTP/1.1 200 Connection established\r\n\r\nHTTP/1.1 '+status+' Result\r\n'
    if headers:
        text += 'Upgrade: WebSocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Accept: '+accept+'\r\n'
    return text + 'Set-Cookie: SECRET_COOKIE\r\nLocation: https://SECRET_LOCATION\r\n\r\nMNC_METRICS '+metrics+' 0.01 0.02 0.03 0.04 0.05 0\n'


MOCK = r'''
import os, sys, json, base64, hashlib
name=os.path.basename(sys.argv[0]); args=sys.argv[1:]; scenario=os.environ['MNC_SCENARIO']
if name=='uname': print('Darwin' if args==['-s'] else 'arm64' if args==['-m'] else '24.0')
elif name=='id': print('501')
elif name=='sw_vers': print('15.0')
elif name=='sysctl': print('1' if 'hw.optional.arm64' in args else '0')
elif name=='ifconfig':
    assert args==['-l']; print('lo0 en0 utun1 utun2')
elif name=='PlistBuddy':
    key=args[1].split(':')[-1]
    print(('16.0' if scenario=='incompatible' else '14.0') if key=='LSMinimumSystemVersion' else '26.1007.30912')
elif name=='launchctl':
    assert len(args)==2 and args[0]=='getenv', 'write attempted'
    allowed={'HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','http_proxy','https_proxy','all_proxy','NO_PROXY','no_proxy','WS_PROXY','WSS_PROXY','CODEX_CA_CERTIFICATE','SSL_CERT_FILE','SSL_CERT_DIR','CURL_CA_BUNDLE'}
    assert args[1] in allowed, 'unexpected environment enumeration'
    if scenario=='conflict' and args[1]=='HTTPS_PROXY': print('http://127.0.0.1:65432')
    if scenario=='conflict' and args[1]=='NO_PROXY': print('chatgpt.com')
elif name=='scutil':
    if '--proxy' in args:
        print('HTTPEnable : 1\nHTTPProxy : 127.0.0.1\nHTTPPort : 7897\nHTTPSEnable : 1\nHTTPSProxy : SECRET_REMOTE\nHTTPSPort : 7897\nProxyAutoConfigEnable : 1\nProxyAutoConfigURLString : https://SECRET_SUBSCRIPTION')
    else: print('nameserver[0] : 192.0.2.53\nflags : Request A records')
elif name=='nc':
    available=scenario!='no_proxy' and args[-1]=='7897'
    if scenario=='ipv6_listener': available=available and '::1' in args
    sys.exit(0 if available else 1)
elif name=='dscacheutil':
    if scenario!='dns': print('ip_address: 198.18.1.2\nipv6_address: 2001:db8::1')
elif name=='curl':
    if '--version' in args: print('curl 8.7.1 (offline mock)'); sys.exit(0)
    assert args[0]=='-q' and '--silent' in args and '--proto' in args
    assert '-k' not in args and '--insecure' not in args and '-L' not in args
    assert '--netrc' not in args and '-u' not in args and '--cookie' not in args
    assert args[args.index('--output')+1]=='/dev/null'
    assert args[args.index('--dump-header')+1]=='-'
    for k in ('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','http_proxy','https_proxy','all_proxy','NO_PROXY','no_proxy','CODEX_CA_CERTIFICATE','SSL_CERT_FILE','SSL_CERT_DIR','CURL_CA_BUNDLE','WS_PROXY','WSS_PROXY'):
        assert k not in os.environ, 'inherited routing or CA leaked'
    route=args[args.index('--proxy')+1]; url=args[-1]
    assert url in {'https://chatgpt.com/','https://auth.openai.com/','https://auth0.openai.com/','https://api.openai.com/v1/models','https://github.com/','https://api.github.com/','https://codex-cloud-backend.chatgpt.com/','https://chatgpt.com/backend-api/codex/responses','https://api.openai.com/v1/responses'}
    if route: assert route.startswith(('http://127.0.0.1:','socks5h://127.0.0.1:','http://[::1]:','socks5h://[::1]:'))
    upgrade='Upgrade: websocket' in args
    rc=0; code='401' if '/v1/models' in url else '403' if 'auth' in url else '200'
    if upgrade: code='401'
    if scenario=='timeout' and not route: rc=28; code='000'
    if scenario=='tls': rc=60; code='000'
    if scenario=='dns': rc=6; code='000'
    if scenario=='preflight' and url=='https://github.com/': rc=28; code='000'
    if scenario=='ipv6_path' and '-6' in args: rc=7; code='000'
    if scenario=='mixed' and not upgrade and url.endswith('/codex/responses'):
        counter=os.path.join(os.environ['MNC_COUNTER'],hashlib.sha256((route+url).encode()).hexdigest())
        n=int(open(counter).read())+1 if os.path.exists(counter) else 1
        open(counter,'w').write(str(n))
        if n==2: rc=28; code='000'
    print('HTTP/1.1 200 Connection established\r\n\r\n',end='')
    if upgrade and scenario in ('valid101','invalid101'):
        rc=28; code='101'
        nonce=next(a.split(': ',1)[1] for a in args if a.startswith('Sec-WebSocket-Key: '))
        assert len(base64.b64decode(nonce))==16
        accept=base64.b64encode(hashlib.sha1((nonce+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        if scenario=='invalid101': accept='bad'
        print('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '+accept+'\r\n',end='')
    else: print('HTTP/1.1 '+code+' Result\r\n',end='')
    print('Set-Cookie: SECRET_COOKIE\r\nLocation: https://SECRET_LOCATION\r\n\r\n',end='')
    verify='20' if rc==60 else '0'
    print('MNC_METRICS '+code+' 0.01 0.02 0.03 0.04 0.05 '+verify)
    sys.exit(rc)
'''


class ParserTests(unittest.TestCase):
    def test_valid101_and_header_redaction(self):
        v=awk_response(response())
        self.assertEqual(v, ['101','0.01','0.02','0.03','0.04','0.05','0','101','1','1','1','1'])
        self.assertNotIn('SECRET', ' '.join(v))

    def test_connect200_is_not_origin_success(self):
        v=awk_response(response(status='401', metrics='401', headers=False))
        self.assertEqual(v[7:11], ['401','0','0','0'])

    def test_wrong_accept_and_missing_upgrade(self):
        self.assertEqual(awk_response(response(accept='wrong'))[10], '0')
        self.assertEqual(awk_response(response(headers=False))[8:11], ['0','0','0'])

    def test_bad_metrics_and_header_injection(self):
        v=awk_response('HTTP/1.1 200 OK\nSet-Cookie: SECRET\nMNC_METRICS 200 SECRET 0 0 0 0 0\n')
        self.assertEqual(v[:7], ['000','0','0','0','0','0','999'])
        self.assertEqual(v[-1], '0')
        v=awk_response(response()+response(status='403',metrics='403',headers=False))
        self.assertEqual(v[7:11], ['403','0','0','0'])

    def test_bounded_resolver(self):
        start=SOURCE.index('bounded() {'); end=SOURCE.index('\nvalue()',start)
        with tempfile.TemporaryDirectory() as tmp:
            harness='scratch='+repr(tmp)+'\n'+SOURCE[start:end]+'\nbounded 1 sleep 20\nexit $?\n'
            before=time.monotonic()
            p=subprocess.run(['bash','-c',harness],capture_output=True,text=True,timeout=4)
            self.assertNotEqual(p.returncode,0)
            self.assertLess(time.monotonic()-before,3)


class GuardTests(unittest.TestCase):
    def test_syntax_and_platform(self):
        for path in [ROOT/'diagnose-macos.sh',ROOT/'diagnose-codex.command',ROOT/'lib/env-check.sh']:
            subprocess.run(['bash','-n',str(path)],check=True)
        args_cases=[(['--help'],0),(['--bad'],2),(['--http-port','x'],2),(['--http-port','0'],2),(['--socks-port','65536'],2),(['--http-port'],2)]
        for args,code in args_cases:
            self.assertEqual(subprocess.run(['bash',str(ROOT/'diagnose-macos.sh')]+args,capture_output=True).returncode,code)
        if sys.platform!='darwin':
            p=subprocess.run(['bash',str(ROOT/'diagnose-macos.sh')],capture_output=True,text=True)
            self.assertEqual(p.returncode,1); self.assertIn('Mac 本机',p.stderr)


class IntegrationTests(unittest.TestCase):
    def test_offline_scenarios(self):
        scenarios=['success','no_proxy','timeout','tls','dns','conflict','valid101','invalid101','preflight','ipv6_listener','ipv6_path','incompatible','mixed']
        with tempfile.TemporaryDirectory(prefix='codex offline 中文 ') as tmp:
            root=Path(tmp); bindir=root/'bin'; bindir.mkdir()
            for name in ['uname','id','sw_vers','sysctl','ifconfig','PlistBuddy','launchctl','scutil','nc','dscacheutil','curl']:
                f=bindir/name; f.write_text('#!'+sys.executable+'\n'+MOCK); f.chmod(0o700)
            adapted=SOURCE.replace('PATH=/usr/bin:/bin:/usr/sbin:/sbin',f'PATH="{bindir}:/usr/bin:/bin:/usr/sbin:/sbin"').replace('/usr/bin/curl','"'+str(bindir/'curl')+'"').replace('/usr/libexec/PlistBuddy','"'+str(bindir/'PlistBuddy')+'"')
            # Shorten only the mock resolver's watchdog; its timeout behavior is tested separately.
            adapted=adapted.replace('bounded 6 dscacheutil','bounded 1 dscacheutil')
            script=root/'diagnose-macos.sh'; script.write_text(adapted)
            shutil.copytree(ROOT/'lib',root/'lib')
            shutil.copy2(ROOT/'diagnose-codex.command',root/'diagnose-codex.command')
            for scenario in scenarios:
                with self.subTest(scenario=scenario):
                    home=root/scenario; home.mkdir(); counter=home/'counters'; counter.mkdir()
                    app=home/'Applications/Codex.app/Contents'; app.mkdir(parents=True)
                    (app/'Info.plist').write_text('offline metadata fixture')
                    config=home/'.codex/config.toml'; config.parent.mkdir()
                    config.write_text('SECRET_CONFIG_API_KEY=do_not_read\n')
                    env=dict(os.environ,HOME=str(home),MNC_SCENARIO=scenario,MNC_COUNTER=str(counter),API_KEY='SECRET_KEY',HTTP_PROXY='http://SECRET_PASSWORD@127.0.0.1:7897',http_proxy='http://127.0.0.1:7897',CODEX_CA_CERTIFICATE='/SECRET_CERT_PATH')
                    before=config.read_bytes()
                    command=['bash',str(root/'diagnose-codex.command')]
                    if scenario!='success': command+=['--quick']
                    p=subprocess.run(command,env=env,capture_output=True,text=True,timeout=45)
                    self.assertEqual(p.returncode,0,(scenario,p.stdout[-2000:],p.stderr))
                    self.assertIn('完成。报告仅保存在',p.stdout)
                    reports=list(home.glob('Library/Logs/mac-network-config/run-*'))
                    self.assertEqual(len(reports),1)
                    report=reports[0]
                    disk_text='\n'.join(f.read_text() for f in report.iterdir())
                    for secret in ['SECRET_CONFIG_API_KEY','SECRET_KEY','SECRET_COOKIE','SECRET_LOCATION','SECRET_PASSWORD','SECRET_REMOTE','SECRET_SUBSCRIPTION','SECRET_CERT_PATH']:
                        self.assertNotIn(secret,p.stdout+p.stderr+disk_text)
                    self.assertEqual(config.read_bytes(),before)
                    self.assertEqual(report.stat().st_mode & 0o077,0)
                    for f in report.iterdir(): self.assertEqual(f.stat().st_mode & 0o077,0)
                    rows=[r.split() for r in (report/'观测.tsv').read_text().splitlines() if not r.startswith('#')]
                    ws=[r for r in rows if r[3]=='ws']
                    https=[r for r in rows if r[3]=='https' and r[4]=='auto']
                    self.assertEqual(len(ws),4 if scenario=='no_proxy' else 12)
                    self.assertEqual(len(https),72 if scenario=='success' else 16 if scenario=='no_proxy' else 48)
                    self.assertTrue(all(len(r)==9 for r in rows))
                    if scenario in ('success','no_proxy','valid101','invalid101','ipv6_listener','incompatible','conflict'):
                        self.assertTrue(all(r[5]=='0' and r[6]!='000' for r in https),https)
                    if scenario=='valid101':
                        self.assertTrue(all(r[8]=='valid101' and r[5]=='28' for r in ws))
                        self.assertNotIn('未验证任何有效 WebSocket',p.stdout)
                    elif scenario=='invalid101':
                        self.assertTrue(all(r[8]=='unverified' for r in ws)); self.assertIn('收到 101 但',p.stdout)
                    elif scenario=='timeout': self.assertIn('Codex 端点代理路径收到响应',p.stdout)
                    elif scenario=='no_proxy': self.assertIn('未自动验证可用的本机代理路径',p.stdout)
                    elif scenario=='dns': self.assertIn('7 / 7',p.stdout)
                    elif scenario=='tls': self.assertIn('TLS 类失败',p.stdout)
                    elif scenario=='conflict': self.assertIn('NO_PROXY 可能',p.stdout); self.assertIn('可能旧端口残留',p.stdout)
                    elif scenario=='preflight': self.assertIn('协议预检未验证，保留对照',p.stdout)
                    elif scenario=='ipv6_listener': self.assertIn('http [::1] 本机端口 7897',p.stdout)
                    elif scenario=='ipv6_path': self.assertIn('IPv4 收到响应而 IPv6 失败',p.stdout)
                    elif scenario=='incompatible': self.assertIn('最低版本',p.stdout)
                    elif scenario=='mixed': self.assertIn('间歇性传输异常',p.stdout)
                    else: self.assertIn('未验证任何有效 WebSocket',p.stdout)
                    print('PASS offline scenario:',scenario,flush=True)


if __name__=='__main__':
    unittest.main(verbosity=2)
