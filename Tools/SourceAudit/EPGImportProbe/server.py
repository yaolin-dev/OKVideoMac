"""Loopback-only deterministic import transport fixture. No upstream requests."""
import argparse
import json
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import time

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def do_GET(self):
        name = self.path.split('?', 1)[0].lstrip('/')
        if name in ('redirect', 'foreign', 'loop'):
            self.send_response(302)
            host = 'localhost' if name == 'foreign' else '127.0.0.1'
            target = 'loop' if name == 'loop' else 'fixture.xml'
            self.send_header('Location', f'http://{host}:{self.server.server_port}/{target}')
            self.send_header('Content-Length', '0'); self.end_headers(); return
        if name == 'empty':
            payload = b'<tv/>'
        elif name == 'invalid':
            payload = b'<tv><programme/></tv>'
        else:
            file = self.server.root / ('fixture.xml' if name in ('slow', 'truncate', 'encoded') else name)
            if not file.is_file() or file.parent != self.server.root:
                self.send_error(404); return
            payload = file.read_bytes()  # server runs in a separate process
        with (self.server.root / 'requests.jsonl').open('a') as log:
            log.write(json.dumps({'path': name, 'host': self.headers.get('Host'),
                'authorization': self.headers.get('Authorization') is not None,
                'proxyAuthorization': self.headers.get('Proxy-Authorization') is not None,
                'acceptEncoding': self.headers.get('Accept-Encoding'),
                'range': self.headers.get('Range')}) + '\n')
        self.send_response(200)
        self.send_header('Content-Length', str(len(payload)))
        self.send_header('Connection', 'close')
        if name == 'encoded': self.send_header('Content-Encoding', 'gzip')
        self.end_headers()
        try:
            if name == 'slow': time.sleep(2)
            if name == 'truncate': payload = payload[:len(payload)//2]
            for offset in range(0, len(payload), 65536): self.wfile.write(payload[offset:offset+65536])
        except (BrokenPipeError, ConnectionResetError): pass
        self.close_connection = True
    def log_message(self, *args): pass

if __name__ == '__main__':
    p = argparse.ArgumentParser(); p.add_argument('root', type=Path); a = p.parse_args()
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler); server.root = a.root.resolve()
    # Existence is the parent's readiness signal: publish only a complete value.
    pending_port = server.root / 'port.pending'
    pending_port.write_text(str(server.server_port))
    pending_port.replace(server.root / 'port')
    server.serve_forever()
