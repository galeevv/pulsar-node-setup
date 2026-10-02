#!/usr/bin/env python3
"""Render real installer templates; test isolated nginx on loopback, never /etc/nginx."""
import http.client
import http.server
import os
from pathlib import Path
import re
import shlex
import socket
import ssl
import subprocess
import tempfile
import threading
import time

script = (Path(__file__).resolve().parents[1] / 'new-node.sh').read_text()
templates = re.findall(r'cat > "\$NGINX_CANDIDATE" <<EOF\n(.*?)\nEOF', script, re.S)
assert len(templates) == 2

def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]

class Backend(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write((self.path + ':' + str(len(self.headers.get('stream', '')))).encode())
    def log_message(self, *args):
        pass

with tempfile.TemporaryDirectory(prefix='pulsar-nginx-test-') as directory:
    root = Path(directory)
    root.chmod(0o755)
    (root / 'index.html').write_text('decoy')
    (root / 'index.html').chmod(0o644)
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                    '-subj', '/CN=node.example.com', '-keyout', str(root / 'key'),
                    '-out', str(root / 'cert')], check=True, capture_output=True)
    backend = http.server.HTTPServer(('127.0.0.1', 0), Backend)
    threading.Thread(target=backend.serve_forever, daemon=True).start()
    try:
        for index, template in enumerate(templates):
            for path in (['/stream/', '/stream'] if index == 0 else ['/stream/']):
                http_port, tls_port = free_port(), free_port()
                values = dict(DOMAIN='node.example.com', CDN_DOMAIN='cdn.example.com',
                              TUNNEL_PATH=path, XRAY_PORT=str(backend.server_port),
                              SELFSTEAL_SITE_PORT=str(tls_port), WEBROOT=str(root))
                shell = '\n'.join(k+'='+shlex.quote(v) for k,v in values.items())
                shell += '\ncat <<EOF\n' + template + '\nEOF\n'
                config = subprocess.run(['bash'], input=shell, text=True, capture_output=True, check=True).stdout
                config = re.sub(r'^\s*listen \[::\]:.*?;\n', '', config, flags=re.M)
                config = config.replace('listen 80 ', f'listen 127.0.0.1:{http_port} ')
                config = config.replace('listen 443 ', f'listen 127.0.0.1:{tls_port} ')
                config = config.replace('/etc/letsencrypt/live/node.example.com/fullchain.pem', str(root / 'cert'))
                config = config.replace('/etc/letsencrypt/live/node.example.com/privkey.pem', str(root / 'key'))
                config = config.replace('/var/log/nginx/', str(root) + '/')
                full = f'pid {root}/nginx.pid; error_log {root}/error.log; events {{ worker_connections 128; }} http {{ access_log off; {config} }}'
                filename = root / 'nginx.conf'
                filename.write_text(full)
                subprocess.run(['nginx', '-t', '-p', str(root)+'/', '-c', str(filename)], check=True, capture_output=True)
                process = subprocess.Popen(['nginx', '-p', str(root)+'/', '-c', str(filename), '-g', 'daemon off;'], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                try:
                    for attempt in range(50):
                        try:
                            with socket.create_connection(('127.0.0.1', tls_port), timeout=.1):
                                break
                        except OSError:
                            time.sleep(.1)
                    else:
                        raise AssertionError('test nginx did not start')
                    context = ssl._create_unverified_context()  # ephemeral fixture certificate
                    def request(url, headers=None):
                        conn = http.client.HTTPSConnection('127.0.0.1', tls_port, context=context, timeout=5)
                        conn.request('GET', url, headers={'Host':'node.example.com', **(headers or {})})
                        res = conn.getresponse()
                        result = (res.status, res.read().decode(), dict(res.getheaders()))
                        conn.close()
                        return result
                    assert request('/')[0:2] == (200, 'decoy')
                    if index == 0:
                        for url in ['/stream', '/stream/', '/stream/session/1?offset=3']:
                            status, body, headers = request(url, {'stream':'a'*16000, 'Accept-Encoding':'gzip'})
                            assert status == 200, (url, status, body)
                            assert body.endswith(':16000'), body
                            assert 'Content-Encoding' not in headers
                            assert 'no-store' in headers.get('Cache-Control', '')
                        assert request('/stream/session/1?offset=3')[1].startswith('/stream/session/1?offset=3:')
                        # Full 24 KB raw packet encoded into header fields plus padding.
                        payload = {f'stream-{i}':'a'*min(3000,32000-start)
                                   for i,start in enumerate(range(0,32000,3000))}
                        payload['X-Cache'] = 'p'*1000
                        assert request('/stream/session/2', payload)[0] == 200
                        assert request('/health')[0] == 200
                        assert request('/stream-other')[0] == 404
                    print('PASS nginx:', 'cdn '+path if index == 0 else 'selfsteal TLS site')
                finally:
                    process.terminate()
                    process.communicate(timeout=10)
    finally:
        backend.shutdown()
        backend.server_close()
