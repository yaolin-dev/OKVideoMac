#!/usr/bin/env python3
"""Serve only the named, signed local update artifacts on loopback."""
import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

class Handler(SimpleHTTPRequestHandler):
    def do_GET(self):
        if urlsplit(self.path).path not in ('/appcast.xml','/update.dmg'):
            self.send_error(404)
            return
        super().do_GET()
    def do_HEAD(self):
        if urlsplit(self.path).path not in ('/appcast.xml','/update.dmg'):
            self.send_error(404)
            return
        super().do_HEAD()

if __name__ == '__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--directory',type=Path,required=True)
    parser.add_argument('--port',type=int,default=38473)
    args=parser.parse_args()
    for name in ('appcast.xml','update.dmg'):
        if not (args.directory/name).is_file(): raise SystemExit(f'Missing {name}')
    server=ThreadingHTTPServer(('127.0.0.1',args.port),partial(Handler,directory=str(args.directory.resolve())))
    print(f'Local update test server: http://127.0.0.1:{args.port}/appcast.xml',flush=True)
    try: server.serve_forever()
    except KeyboardInterrupt: pass
    finally: server.server_close()
