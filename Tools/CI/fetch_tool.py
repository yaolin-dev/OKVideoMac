#!/usr/bin/env python3
"""Download a pinned official CI tool and verify its archive before extracting one file."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import platform
import tarfile
import urllib.request


def fetch(name, output):
    lock = json.loads((Path(__file__).parent / 'tool-downloads.json').read_text())
    entry = lock[name]['platforms'][platform.system() + '-' + platform.machine()]
    request = urllib.request.Request(entry['url'], headers={'User-Agent': 'OKVideoMac-CI'})
    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read(64 * 1024 * 1024 + 1)
    if len(data) > 64 * 1024 * 1024 or hashlib.sha256(data).hexdigest() != entry['sha256']:
        raise RuntimeError(f'{name} archive failed size/SHA-256 verification')
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
        member = archive.getmember(entry['member'])
        if not member.isfile():
            raise RuntimeError('Tool archive member is not a regular file')
        binary = archive.extractfile(member).read()
    output.mkdir(parents=True, exist_ok=True)
    executable = output / name
    executable.write_bytes(binary)
    executable.chmod(0o755)
    (output / (name + '-download.json')).write_text(json.dumps(dict(entry, version=lock[name]['version'],
        executableSHA256=hashlib.sha256(binary).hexdigest()), indent=2) + '\n')
    return executable


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('tool', choices=['actionlint'])
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    print(fetch(args.tool, args.output))
