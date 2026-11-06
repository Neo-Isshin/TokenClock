"""Build the production transport and test only loopback proxy/target sockets.

No system proxy changes, credentials, DNS targets or external network requests.
"""
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]


class Server:
    def __init__(self, mode, family=socket.AF_INET, tls=None):
        self.mode = mode; self.requests = []; self.stopped = threading.Event()
        self.tls = tls
        self.sock = socket.socket(family); self.sock.bind(('::1' if family == socket.AF_INET6 else '127.0.0.1', 0))
        self.sock.listen(); self.sock.settimeout(.1)
        self.port = self.sock.getsockname()[1]
        self.thread = threading.Thread(target=self.run, daemon=True); self.thread.start()

    def run(self):
        while not self.stopped.is_set():
            try: conn, _ = self.sock.accept()
            except socket.timeout: continue
            except OSError: break
            with conn:
                conn.settimeout(1)
                try:
                    if self.mode == 'direct-tls': conn = self.tls.wrap_socket(conn, server_side=True)
                    data = b''
                    while b'\r\n\r\n' not in data and len(data) < 16384:
                        part = conn.recv(4096)
                        if not part: break
                        data += part
                    self.requests.append(data)
                    if self.mode == 'stall': self.stopped.wait(2); continue
                    if self.mode == 'close': continue
                    if self.mode in ('502', '407'):
                        conn.sendall(('HTTP/1.1 '+self.mode+' Failed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n').encode()); continue
                    if data.startswith(b'CONNECT '):
                        conn.sendall(b'HTTP/1.1 200 Connection established\r\n\r\n')
                        conn = self.tls.wrap_socket(conn, server_side=True)
                        data = b''
                        while b'\r\n\r\n' not in data and len(data) < 16384:
                            part = conn.recv(4096)
                            if not part: break
                            data += part
                        self.requests.append(data)
                    if self.mode.startswith('redirect:'):
                        response = 'HTTP/1.1 302 Found\r\nLocation: '+self.mode[len('redirect:'):]+'\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
                        conn.sendall(response.encode())
                    elif self.mode == 'drop-body':
                        conn.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 1000\r\nConnection: close\r\n\r\npartial')
                        conn.shutdown(socket.SHUT_RDWR); conn.close()
                    else: conn.sendall(b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}')
                except (OSError, socket.timeout): pass

    def close(self):
        self.stopped.set(); self.sock.close(); self.thread.join(timeout=3)


def main():
    with tempfile.TemporaryDirectory(prefix='tc-claude-proxy-test-') as td:
        exe = Path(td)/'proxy-smoke'
        subprocess.run(['swiftc','-D','TOKENCLOCK_PROXY_TESTS','-sdk','/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk',
            str(ROOT/'Sources/TokenClock/Config/SettingsKeys.swift'), str(ROOT/'Sources/TokenClock/Services/ClaudeQuotaNetwork.swift'), str(ROOT/'Tests/ClaudeQuotaProxySmoke.swift'), '-o',str(exe)], check=True)
        cert=Path(td)/'certificate.pem';key=Path(td)/'key.pem'
        config=Path(td)/'openssl.cnf'
        config.write_text('[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=localhost\n[ext]\nsubjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,digitalSignature,keyEncipherment,keyCertSign\nextendedKeyUsage=serverAuth\n')
        subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1','-config',str(config),'-keyout',str(key),'-out',str(cert)],check=True,capture_output=True)
        tls=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);tls.load_cert_chain(cert,key)
        env = {k:v for k,v in os.environ.items() if 'proxy' not in k.lower()}
        # Hostile ambient bypass/config settings must not alter the pinned request.
        (Path(td)/'.curlrc').write_text('noproxy = "*"\nlocation\ninsecure\n')
        env.update(NO_PROXY='*', no_proxy='*', ALL_PROXY='http://127.0.0.1:1', CURL_HOME=td)
        policy = json.loads(subprocess.check_output([str(exe)], env=env, text=True))
        records = []; direct_records = []
        for family in (socket.AF_INET, socket.AF_INET6):
            target = Server('direct-target', family); destination = '::1' if family==socket.AF_INET6 else '127.0.0.1'
            target_url = f'https://[{destination}]:{target.port}/fixture' if family==socket.AF_INET6 else f'https://{destination}:{target.port}/fixture'
            try:
                for mode in ('success', '502', '407', 'close', 'drop-body', 'stall', 'refused', 'tls-invalid', 'redirect:'+target_url+'/other'):
                    proxy = Server(mode, tls=tls)
                    if mode == 'refused': proxy.close()
                    try:
                        result = subprocess.run([str(exe),'--wire'], input=json.dumps({'proxy':f'http://127.0.0.1:{proxy.port}', 'target':target_url,'timeout':1.5,
                            **({'fixture_anchor':str(cert)} if mode!='tls-invalid' else {})}),
                            env=env,text=True,capture_output=True,timeout=8,check=True)
                        value=json.loads(result.stdout)
                        assert value['success'] == (mode=='success'), (mode, value, 'proxy_receipts', len(proxy.requests), 'target_receipts',len(target.requests),result.stderr[-600:])
                        assert not target.requests, 'Direct target reached after '+mode
                        if mode=='success':
                            assert any(b'SYNTHETIC-NOT-A-CREDENTIAL' in r for r in proxy.requests)
                            assert any(b'SYNTHETIC-NOT-A-COOKIE' in r for r in proxy.requests)
                        if mode.startswith('redirect:'): assert len(proxy.requests)==2, 'Redirect was followed'
                        records.append({'ip':4 if family==socket.AF_INET else 6,'case':mode.split(':')[0],
                                        'passed':True,'proxy_connections':len(proxy.requests),'direct_connections':len(target.requests)})
                    finally: proxy.close()
            finally: target.close()
            direct = Server('direct-tls',family,tls=tls)
            url = f'https://[::1]:{direct.port}/fixture' if family==socket.AF_INET6 else f'https://127.0.0.1:{direct.port}/fixture'
            try:
                for strict in (False,True):
                    for tun in (False,True):
                        before=len(direct.requests)
                        result=subprocess.run([str(exe),'--wire'],input=json.dumps({'target':url,'timeout':1.5,'fixture_anchor':str(cert),
                            'require_proxy':strict,'system':{'__SCOPED__':{'utun8':{}}} if tun else {}}),env=env,text=True,capture_output=True,timeout=8,check=True)
                        value=json.loads(result.stdout)
                        assert value['success'] is not strict,(strict,tun,value)
                        connections=len(direct.requests)-before
                        assert connections==(0 if strict else 1),(strict,tun,connections)
                        direct_records.append({'ip':4 if family==socket.AF_INET else 6,'require_proxy':strict,'tun_configuration_fixture':tun,
                            'passed':True,'allowed_direct_connections':connections,'blocked_before_network':value.get('blocked',False)})
            finally:direct.close()
        print(json.dumps({'policy':policy,'network_cases':records,'route_policy_cases':direct_records,
            'actual_tun_created':False,'model_calls':0,'real_credentials_used':False},indent=2))


if __name__ == '__main__': main()
