#!/usr/bin/env python3
"""Exercise the actual supplied libmpv/FFmpeg, not a system ffmpeg executable."""
import argparse
import ctypes as C
import hashlib
import http.server
import json
from pathlib import Path
import re
import subprocess
import threading
import time
from urllib.parse import urlsplit


_loaded_libraries = {}


def load_library(path):
    """Python lacks the app executable's Frameworks rpath. Load bundled
    dependencies by absolute path first without altering signed libraries."""
    path = Path(path).resolve()
    if path in _loaded_libraries:
        return _loaded_libraries[path]
    dependencies = subprocess.check_output(['otool', '-L', str(path)], text=True).splitlines()[2:]
    for line in dependencies:
        dependency = line.strip().split(' (compatibility version', 1)[0]
        if dependency.startswith('@rpath/'):
            child = path.parent / dependency[len('@rpath/'):]
        elif dependency.startswith('@loader_path/'):
            child = path.parent / dependency[len('@loader_path/'):]
        else:
            continue
        if child.is_file():
            load_library(child)
    library = C.CDLL(str(path), mode=C.RTLD_GLOBAL)
    _loaded_libraries[path] = library
    return library


class Event(C.Structure):
    _fields_ = [('event_id', C.c_int), ('error', C.c_int), ('userdata', C.c_uint64), ('data', C.c_void_p)]


class Player:
    def __init__(self, library, headers=None, extra_options=None):
        self.lib = load_library(library)
        for name, result, args in [
            ('mpv_create', C.c_void_p, []),
            ('mpv_initialize', C.c_int, [C.c_void_p]),
            ('mpv_set_option_string', C.c_int, [C.c_void_p, C.c_char_p, C.c_char_p]),
            ('mpv_get_property_string', C.c_void_p, [C.c_void_p, C.c_char_p]),
            ('mpv_command', C.c_int, [C.c_void_p, C.POINTER(C.c_char_p)]),
            ('mpv_wait_event', C.POINTER(Event), [C.c_void_p, C.c_double]),
            ('mpv_free', None, [C.c_void_p]),
            ('mpv_terminate_destroy', None, [C.c_void_p]),
        ]:
            fn = getattr(self.lib, name)
            fn.restype, fn.argtypes = result, args
        self.handle = self.lib.mpv_create()
        assert self.handle, 'mpv_create failed'
        options = dict(config='no', vo='null', ao='null', hwdec='no', terminal='no',
                       idle='yes', keep_open='yes', network_timeout='15')
        if headers:
            options['http_header_fields'] = headers
        options.update(extra_options or {})
        for key, value in options.items():
            assert self.lib.mpv_set_option_string(self.handle, key.replace('_', '-').encode(), value.encode()) >= 0, key
        assert self.lib.mpv_initialize(self.handle) >= 0, 'mpv_initialize failed'

    def property(self, name):
        value = self.lib.mpv_get_property_string(self.handle, name.encode())
        if not value:
            return None
        try:
            return C.string_at(value).decode()
        finally:
            self.lib.mpv_free(value)

    def command(self, *args):
        array = (C.c_char_p * (len(args) + 1))(*[str(a).encode() for a in args], None)
        assert self.lib.mpv_command(self.handle, array) >= 0, args[0]

    def await_position(self, minimum, timeout=30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            position = float(self.property('time-pos') or '-1')
            if position >= minimum:
                return position
            time.sleep(0.05)
        raise AssertionError('Playback did not reach expected position; media URL omitted')

    def check(self, url, seek=6, before_seek=None):
        self.command('loadfile', url)
        self.await_position(0.3)
        result = {key: self.property(key) for key in
                  ['video-format', 'audio-codec-name', 'video-params/w', 'audio-params/samplerate', 'duration']}
        assert int(result['video-params/w'] or '0') > 0, 'No decoded video'
        assert int(result['audio-params/samplerate'] or '0') > 0, 'No decoded audio'
        if before_seek:
            before_seek()
        self.command('seek', seek, 'absolute+exact')
        position = self.await_position(seek + 0.2)
        assert position < seek + 2, 'Seek missed target'
        result['seek'] = 'passed'
        return result

    def close(self):
        self.lib.mpv_terminate_destroy(self.handle)

    def check_failure(self, url):
        self.command('loadfile', url)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            event = self.lib.mpv_wait_event(self.handle, 0.1).contents
            if event.event_id == 7:  # MPV_EVENT_END_FILE
                reason, error = C.cast(event.data, C.POINTER(C.c_int))[:2]
                assert reason == 4 and error < 0, 'Final representation failure was hidden'
                return
        raise AssertionError('Missing terminal playback failure')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--library', type=Path, required=True)
    parser.add_argument('--ffmpeg', type=Path, required=True)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    ffmpeg = load_library(args.ffmpeg)
    ffmpeg.av_find_input_format.argtypes = [C.c_char_p]
    ffmpeg.av_find_input_format.restype = C.c_void_p
    for name in ['dash', 'hls', 'mov', 'matroska', 'mpegts']:
        assert ffmpeg.av_find_input_format(name.encode()), f'Missing demuxer: {name}'
    fixtures = Path(__file__).resolve().parent.parent / 'Native/DASHSmoke/fixtures'
    for name, expected in json.loads((fixtures / 'SHA256.json').read_text()).items():
        assert hashlib.sha256((fixtures / name).read_bytes()).hexdigest() == expected, name
    requests = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            path = urlsplit(self.path).path
            if self.headers.get('Referer') != 'https://fixture.example/':
                self.send_error(403)
                requests.append({'path': path, 'denied': True})
                return
            if path == '/redirect':
                self.send_response(302)
                self.send_header('Location', '/template/manifest.mpd')
                self.end_headers()
                return
            target = (fixtures / path.lstrip('/')).resolve()
            if not target.is_relative_to(fixtures.resolve()) or not target.is_file():
                self.send_error(404)
                return
            data = target.read_bytes()
            start, end = 0, len(data) - 1
            value = self.headers.get('Range')
            if value:
                match = re.fullmatch(r'bytes=(\d+)-(\d*)', value)
                if not match:
                    self.send_error(416)
                    return
                start = int(match[1])
                end = min(end, int(match[2])) if match[2] else end
            if start > end:
                self.send_error(416)
                return
            requests.append({'path': path, 'range': value, 'bytes': end - start + 1})
            self.send_response(206 if value else 200)
            self.send_header('Content-Type', 'application/dash+xml' if target.suffix == '.mpd' else 'application/octet-stream')
            self.send_header('Accept-Ranges', 'bytes')
            self.send_header('Content-Length', str(end - start + 1))
            if value:
                self.send_header('Content-Range', f'bytes {start}-{end}/{len(data)}')
            self.end_headers()
            try:
                if path.startswith('/seek/') and target.suffix == '.mp4':
                    # Slow enough that reading the whole file cannot masquerade
                    # as a successful byte-range seek beyond the player cache.
                    for offset in range(start, end + 1, 4096):
                        self.wfile.write(data[offset:min(offset + 4096, end + 1)])
                        time.sleep(0.04)
                else:
                    self.wfile.write(data[start:end + 1])
            except (BrokenPipeError, ConnectionResetError):
                pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    results = {}
    try:
        for path in ['template/manifest.mpd', 'base/manifest.mpd', 'base/segment-base.mpd', 'base/unavailable-alternates.mpd',
                     'redirect', 'legacy.mp4', 'legacy.mkv', 'hls/manifest.m3u8']:
            print('Checking ' + path, flush=True)
            player = Player(args.library, 'Referer: https://fixture.example/')
            try:
                results[path] = player.check(f'http://127.0.0.1:{server.server_port}/{path}')
            finally:
                player.close()
        assert not any(r.get('denied') for r in requests), 'Headers lost on child request'
        assert any(r.get('range') and r['path'].endswith('.mp4') for r in requests), 'Byte ranges not exercised'
        assert any('chunk-stream0' in r['path'] for r in requests), 'Video segments not requested'
        assert any('chunk-stream1' in r['path'] for r in requests), 'Audio segments not requested'
        player = Player(args.library, 'Referer: https://fixture.example/',
                        {'cache': 'no', 'demuxer_readahead_secs': '0', 'demuxer_max_bytes': '16KiB'})
        seek_start = []
        try:
            results['single-file-range-seek'] = player.check(
                f'http://127.0.0.1:{server.server_port}/seek/manifest.mpd', seek=300,
                before_seek=lambda: seek_start.append(len(requests)))
        finally:
            player.close()
        after_seek = requests[seek_start[0]:]
        for track in ['manifest-stream0.mp4', 'manifest-stream1.mp4']:
            assert any(r['path'].endswith(track) and r.get('range')
                       and int(r['range'].split('=')[1].split('-')[0]) > 100000 for r in after_seek), \
                'Single-file DASH seek did not request the target range: ' + str([(r['path'], r.get('range')) for r in after_seek])
        player = Player(args.library, 'Referer: https://fixture.example/')
        try:
            player.check_failure(f'http://127.0.0.1:{server.server_port}/base/no-video.mpd')
        finally:
            player.close()
        results['all-video-unavailable'] = {'terminalFailure': 'passed'}
    finally:
        server.shutdown()
        server.server_close()
    report = {'status': 'passed', 'library': str(args.library), 'ffmpeg': str(args.ffmpeg),
              'cases': results, 'httpRequests': requests}
    if args.report:
        args.report.write_text(json.dumps(report, indent=2) + '\n')
    print(f'PASS: {len(results)} native playback cases, decoded video/audio, seek, headers, ranges, redirect and terminal failure')


if __name__ == '__main__':
    main()
