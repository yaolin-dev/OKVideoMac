#!/usr/bin/env python3
"""Prepare the pinned official Sparkle distribution. Never accept an old cache by version alone."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def prepare(output=None):
    lock = json.loads((REPO/'ThirdParty/sparkle-lock.json').read_text())
    cache = Path(os.environ.get('OKVIDEOMAC_BUILD_ROOT', HERE.parent/'Vendor/Build'))/'Downloads'
    cache.mkdir(parents=True, exist_ok=True)
    archive = Path(os.environ.get('OKVIDEOMAC_SPARKLE_ARCHIVE', cache/'Sparkle-2.10.0.tar.xz'))
    if not archive.exists():
        temporary = archive.with_suffix('.incoming')
        subprocess.run(['curl','--fail','--location','--proto','=https','--tlsv1.2',
                        '--output',str(temporary),lock['distribution_url']],check=True)
        if sha(temporary) != lock['distribution_sha256']:
            temporary.unlink()
            raise SystemExit('Sparkle archive hash mismatch')
        temporary.replace(archive)
    if sha(archive) != lock['distribution_sha256']:
        raise SystemExit('Sparkle archive hash mismatch; refusing cached distribution')
    destination = Path(output) if output else HERE.parent/'Vendor/Build/Sparkle'
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='sparkle-',dir=destination.parent) as directory:
        stage=Path(directory)
        subprocess.run(['tar','-xJf',str(archive),'-C',str(stage)],check=True)
        framework=stage/'Sparkle.framework'
        actual=[]
        records=[]
        for path in sorted(framework.rglob('*')):
            if path.is_symlink() or not path.is_file(): continue
            if 'Mach-O' not in subprocess.check_output(['file','-b',str(path)],text=True): continue
            relative=path.relative_to(framework).as_posix()
            actual.append(relative)
            original=sha(path)
            arch=subprocess.check_output(['lipo','-archs',str(path)],text=True).strip()
            if arch != 'arm64':
                thin=path.with_suffix('.arm64-incoming')
                subprocess.run(['lipo',str(path),'-thin','arm64','-output',str(thin)],check=True)
                thin.replace(path)
            records.append({'path':relative,'official_sha256':original,'arm64_sha256':sha(path)})
        if set(actual) != set(lock['macho_paths']):
            raise SystemExit('Sparkle executable inventory differs from the approved lock')
        incoming=stage/'Prepared'
        incoming.mkdir()
        shutil.move(framework,incoming/'Sparkle.framework')
        shutil.copy2(stage/'LICENSE',incoming/'LICENSE')
        (incoming/'provenance.json').write_text(json.dumps({
            'version':lock['version'],'commit':lock['commit'],
            'distribution_sha256':lock['distribution_sha256'],'mach_o':records},indent=2)+'\n')
        if destination.exists(): shutil.rmtree(destination)
        shutil.move(incoming,destination)
    print('Prepared pinned Sparkle 2.10.0: exact five arm64 executables')

if __name__ == '__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--output')
    prepare(parser.parse_args().output)
