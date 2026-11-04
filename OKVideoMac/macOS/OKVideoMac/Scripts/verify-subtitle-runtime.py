#!/usr/bin/env python3
"""Local-only subtitle decoder gate against the exact packaged native engine."""
import argparse
import json
from pathlib import Path
import runpy
import tempfile
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--library', type=Path, required=True)
    parser.add_argument('--fonts', type=Path, required=True)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    scripts = Path(__file__).resolve().parent
    player_type = runpy.run_path(str(scripts / 'verify-dash-playback.py'))['Player']
    video = scripts.parent / 'Native/DASHSmoke/fixtures/legacy.mp4'
    samples = {'utf-8': '简体中文字幕测试；繁體中文字幕測試 English 123',
               'gb18030': '简体中文字幕测试；繁體中文字幕測試 English 123',
               'big5': '繁體中文字幕測試，今天播放正常。 English 123'}
    results = []
    with tempfile.TemporaryDirectory(prefix='OKVideoSubtitleGate-') as temporary:
        for encoding, choice in [('utf-8', 'auto'), ('gb18030', 'auto'), ('big5', 'auto'),
                                 ('gb18030', '+gb18030'), ('big5', '+big5')]:
            subtitle = Path(temporary) / 'fixture.srt'
            subtitle.write_bytes(('1\n00:00:00,000 --> 00:00:30,000\n' + samples[encoding] + '\n').encode(encoding))
            player = player_type(args.library, extra_options=dict(sub_codepage=choice, sub_fonts_dir=str(args.fonts), sub_font='Noto Sans CJK SC'))
            try:
                player.command('loadfile', str(video))
                player.await_position(0.1, timeout=8)
                player.command('sub-add', str(subtitle), 'select')
                deadline = time.monotonic() + 5
                matched = False
                while time.monotonic() < deadline:
                    if player.property('sub-text') == samples[encoding]:
                        matched = True
                        break
                    time.sleep(0.02)
                assert matched, f'Subtitle decoding failed: {encoding}, {choice}'
                results.append(dict(encoding=encoding, selection=choice, status='passed'))
            finally:
                player.close()
    if args.report:
        args.report.write_text(json.dumps(dict(status='passed', tests=results), indent=2) + '\n')
    print('PASS: packaged subtitle decoding (UTF-8, GB18030, Big5; automatic and explicit)')


if __name__ == '__main__':
    main()
