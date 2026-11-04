#!/usr/bin/env python3
"""Render Chinese ASS fixtures using the exact packaged libass (no network)."""
import argparse, hashlib, json, subprocess, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--headers', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    frameworks = args.app.resolve()/'Contents/Frameworks'
    fonts = args.app.resolve()/'Contents/Resources/SubtitleFonts/Fonts'
    font = fonts/'NotoSansCJKsc-Regular.otf'
    assert font.is_file()
    results = []
    with tempfile.TemporaryDirectory(prefix='OKVideoSubtitleGlyphs-') as temporary:
        binary = Path(temporary)/'font-smoke'
        subprocess.run(['clang', '-arch', 'arm64', '-I'+str(args.headers),
            str(ROOT/'OKVideoMac/macOS/OKVideoMac/Native/SubtitleSmoke/font-smoke.c'),
            str(frameworks/'libass.9.dylib'), '-Wl,-rpath,'+str(frameworks), '-o', str(binary)], check=True)
        cases = [('default','Noto Sans CJK SC','auto','common'),
                 ('yahei','Microsoft YaHei','auto','common'),
                 ('simhei','SimHei','auto','common'),
                 ('missing-font','DeliberatelyMissingFont194','auto','common'),
                 ('no-system-fonts','Noto Sans CJK SC','none','common'),
                 ('embedded-font','Noto Sans CJK SC','embedded','common'),
                 ('rare-glyph','Noto Sans CJK SC','none','rare')]
        for name, family, provider, sample in cases:
            ppm = args.output/(name+'.ppm')
            run = subprocess.run([str(binary),family,provider,str(ppm),str(fonts),str(font),sample], text=True, capture_output=True, check=True)
            (args.output/(name+'.log')).write_text(run.stderr)
            result = json.loads(run.stdout)
            assert result['imageLayers'] > 0, name
            if sample == 'common': assert result['fallbackFailures'] == 0, name
            result.update(name=name, sample=sample, status='passed' if sample=='common' else 'coverage-observation')
            results.append(result)
            subprocess.run(['sips','-s','format','png',str(ppm),'--out',str(ppm.with_suffix('.png'))], check=True, capture_output=True)
    (args.output/'summary.json').write_text(json.dumps(dict(status='passed',tests=results,libassSHA256=hashlib.sha256((frameworks/'libass.9.dylib').read_bytes()).hexdigest(),fontSHA256=hashlib.sha256(font.read_bytes()).hexdigest()),ensure_ascii=False,indent=2)+'\n')
    print('PASS: six Chinese rendering scenarios; rare glyph coverage recorded separately')
if __name__ == '__main__': main()
