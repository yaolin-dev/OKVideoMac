#!/usr/bin/env python3
"""Download a pinned official CI tool and verify its archive before extracting one file."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import platform
from pathlib import PurePosixPath
import tempfile
import tarfile
import urllib.request
import zipfile


def install(name, output, entry, data, version):
    if len(data) > 64 * 1024 * 1024 or hashlib.sha256(data).hexdigest() != entry['sha256']:
        raise RuntimeError(f'{name} archive failed size/SHA-256 verification')
    runtime = {}
    if entry.get('format') == 'zip':
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            member = archive.getinfo(entry['member'])
            if member.is_dir() or (member.external_attr >> 16) & 0o170000 == 0o120000:
                raise RuntimeError('Tool archive member is a directory or symlink')
            binary = archive.read(member)
            bundle = entry.get('bundle')
            if bundle:
                prefix = bundle['prefix'].rstrip('/') + '/'
                for item in archive.infolist():
                    if not item.filename.startswith(prefix):
                        continue
                    relative = item.filename[len(prefix):]
                    path = PurePosixPath(relative)
                    if path.is_absolute() or '..' in path.parts or (item.external_attr >> 16) & 0o170000 == 0o120000:
                        raise RuntimeError('Unsafe tool bundle member')
                    if item.is_dir():
                        continue
                    if not relative or relative in runtime:
                        raise RuntimeError('Invalid or duplicate tool bundle member')
                    if item.file_size + sum(map(len, runtime.values())) > 64 * 1024 * 1024:
                        raise RuntimeError('Tool bundle exceeds size limit')
                    runtime[relative] = archive.read(item)
                if sum(map(len, runtime.values())) > 64 * 1024 * 1024:
                    raise RuntimeError('Tool bundle exceeds size limit')
                if not all(path in runtime for path in bundle['requiredFiles']):
                    raise RuntimeError('Tool bundle is missing required runtime resources')
                if runtime.get(bundle['executable']) != binary:
                    raise RuntimeError('Tool bundle executable differs from pinned member')
    else:
        with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
            member = archive.getmember(entry['member'])
            if not member.isfile():
                raise RuntimeError('Tool archive member is not a regular file')
            binary = archive.extractfile(member).read()
    output.mkdir(parents=True, exist_ok=True)
    executable = output / name
    record = dict(entry, version=version, executableSHA256=hashlib.sha256(binary).hexdigest())
    if runtime:
        # XcodeGen resolves SettingPresets relative to its installed executable.
        # Preserve the official bin/ + share/ tree rather than copying only bin.
        package = output / (name + '-' + entry['sha256'][:12])
        inventory = {path: hashlib.sha256(value).hexdigest() for path, value in runtime.items()}
        if package.exists():
            actual = {p.relative_to(package).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                      for p in package.rglob('*') if p.is_file() and not p.is_symlink()}
            if actual != inventory or any(p.is_symlink() for p in package.rglob('*')):
                raise RuntimeError('Existing tool bundle differs from pinned archive')
        else:
            with tempfile.TemporaryDirectory(prefix=name + '-install-', dir=output) as directory:
                stage = Path(directory) / 'package'
                for path, value in runtime.items():
                    target = stage / path
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(value)
                    target.chmod(0o755 if path == entry['bundle']['executable'] else 0o644)
                stage.replace(package)
        target = package.relative_to(output) / entry['bundle']['executable']
        launcher = ("#!/usr/bin/env python3\nfrom pathlib import Path\nimport os, sys\n"
                    "tool = Path(__file__).resolve().parent / " + repr(target.as_posix()) + "\n"
                    "os.execv(str(tool), [str(tool), *sys.argv[1:]])\n")
        executable.write_text(launcher)
        record.update(installedExecutable=target.as_posix(), runtimeFiles=inventory,
                      launcherSHA256=hashlib.sha256(launcher.encode()).hexdigest())
    else:
        executable.write_bytes(binary)
    executable.chmod(0o755)
    (output / (name + '-download.json')).write_text(json.dumps(record, indent=2) + '\n')
    return executable


def fetch(name, output):
    lock = json.loads((Path(__file__).parent / 'tool-downloads.json').read_text())
    entry = lock[name]['platforms'][platform.system() + '-' + platform.machine()]
    request = urllib.request.Request(entry['url'], headers={'User-Agent': 'OKVideoMac-CI'})
    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read(64 * 1024 * 1024 + 1)
    return install(name, output, entry, data, lock[name]['version'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('tool', choices=['actionlint', 'xcodegen'])
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    print(fetch(args.tool, args.output))
