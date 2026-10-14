#!/usr/bin/env python3
"""Archive matching dSYMs before strip; verify the final bundle without uploading."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

REQUIRED = ['Contents/MacOS/OKVideoMac', 'Contents/Helpers/OKVideoMacRelauncher']
MAGIC = {bytes.fromhex(x) for x in ['feedface', 'cefaedfe', 'feedfacf', 'cffaedfe',
                                  'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca']}


def output(*args):
    return subprocess.check_output([str(a) for a in args], text=True).strip()


def sha(path):
    with path.open('rb') as f:
        digest = hashlib.sha256()
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def uuids(path):
    result = {arch: uuid.upper() for uuid, arch in re.findall(
        r'UUID: ([A-Fa-f0-9-]+) \(([^)]+)\)', output('xcrun', 'dwarfdump', '--uuid', path))}
    if not result or 'arm64' not in result:
        raise ValueError(f'Missing arm64 UUID: {path.name}')
    return result


def identity(app):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    return {k: info[k] for k in ['CFBundleIdentifier', 'CFBundleShortVersionString', 'CFBundleVersion']}


def inventory(app):
    images = []
    for path in sorted((app / 'Contents').rglob('*')):
        if path.is_symlink() or not path.is_file() or any(p.suffix == '.dSYM' for p in path.parents):
            continue
        with path.open('rb') as f:
            if f.read(4) not in MAGIC:
                continue
        images.append({'path': path.relative_to(app).as_posix(), 'uuids': uuids(path),
                       'sha256': sha(path)})
    if not images:
        raise ValueError('No Mach-O images in bundle')
    return images


def source_state(repo):
    # Frozen local acceptance source has no .git directory. Validate every
    # captured byte and preserve its explicit non-release identity instead of
    # pretending the baseline commit contains the implementation changes.
    if (repo / 'LOCAL_ACCEPTANCE_SNAPSHOT.json').is_file():
        sys.path.insert(0, str(repo / 'Tools/SourceAudit'))
        from local_acceptance import validate
        snapshot = validate(repo)
        return {'commit': None, 'baseline_commit': snapshot['base_git_commit'],
                'branch': snapshot['branch'], 'dirty': True,
                'working_files_sha256': snapshot['source_sha256'],
                'source_digest_format': 'local-acceptance-manifest-v1',
                'acceptanceOnly': True, 'publicReleaseEligible': False,
                'gitCommitBound': False}
    # This local-only manifest records the exact modified source contents, not secrets or a source archive.
    names = subprocess.check_output(['git', '-C', str(repo), 'ls-files', '-z', '--cached',
                                     '--others', '--exclude-standard']).split(b'\0')
    tree = hashlib.sha256()
    for name in sorted(set(n for n in names if n)):
        p = repo / name.decode()
        if p.is_file() and not p.is_symlink():
            tree.update(name + b'\0' + sha(p).encode() + b'\n')
    return {'commit': output('git', '-C', repo, 'rev-parse', 'HEAD'),
            'dirty': bool(output('git', '-C', repo, 'status', '--porcelain')),
            'working_files_sha256': tree.hexdigest()}


def symbol_index(roots):
    result = {}
    for root in roots:
        bundles = [root] if root.suffix == '.dSYM' else sorted(root.glob('*.dSYM'))
        for bundle in bundles:
            for dwarf in sorted((bundle / 'Contents/Resources/DWARF').glob('*')):
                if dwarf.is_file():
                    for arch, uuid in uuids(dwarf).items():
                        result.setdefault((arch, uuid), (bundle, dwarf))
    return result


def archive(args):
    if args.output.exists() and any(args.output.iterdir()):
        raise ValueError('Archive directory must be empty; never overwrite earlier build symbols')
    args.output.mkdir(parents=True, exist_ok=True)
    index = symbol_index(args.symbols)
    images = inventory(args.app)
    copied = {}
    for image in images:
        matches = []
        for arch, uuid in image['uuids'].items():
            match = index.get((arch, uuid))
            if not match:
                continue
            bundle, dwarf = match
            key = str(bundle.resolve())
            if key not in copied:
                relative = Path('symbols') / f'{len(copied):02d}-{bundle.name}'
                shutil.copytree(bundle, args.output / relative)
                copied[key] = relative
            archived_dwarf = copied[key] / dwarf.relative_to(bundle)
            matches.append({'architecture': arch, 'uuid': uuid,
                            'dwarf': archived_dwarf.as_posix(), 'sha256': sha(args.output / archived_dwarf)})
        image['symbols'] = matches
        image['symbol_status'] = 'MATCHED' if len(matches) == len(image['uuids']) else 'MISSING_DSYM'
    for required in REQUIRED + args.require:
        found = next((i for i in images if i['path'] == required), None)
        if not found or found['symbol_status'] != 'MATCHED':
            raise ValueError(f'Required matching dSYM unavailable: {required}')
    manifest = {'schema': 1, 'kind': args.kind, 'identity': identity(args.app),
                'source': source_state(args.repo), 'images_before_strip': images,
                'required_images': REQUIRED + args.require,
                'scope': 'local debug information only; no upload; missing dSYMs are explicit coverage gaps'}
    (args.output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'Archived {len(copied)} matching dSYM bundles; {sum(i["symbol_status"] != "MATCHED" for i in images)} image gaps')


def verify(args):
    manifest = json.loads((args.archive / 'manifest.json').read_text())
    if identity(args.app) != manifest['identity']:
        raise ValueError('App identity/version changed after symbol archive')
    current = inventory(args.app)
    by_path = {i['path']: i for i in current}
    for original in manifest['images_before_strip']:
        final = by_path.get(original['path'])
        if final is None or final['uuids'] != original['uuids']:
            raise ValueError(f'UUID/image mismatch after strip/sign: {original["path"]}')
        final['symbols'] = original['symbols']
        for symbol in original['symbols']:
            dwarf = args.archive / symbol['dwarf']
            if sha(dwarf) != symbol['sha256'] or uuids(dwarf).get(symbol['architecture']) != symbol['uuid']:
                raise ValueError('Archived dSYM hash/UUID changed')
        final['symbol_status'] = original['symbol_status']
    for image in current:
        image.setdefault('symbols', [])
        image.setdefault('symbol_status', 'MISSING_DSYM')
    for required in manifest['required_images']:
        if by_path[required]['symbol_status'] != 'MATCHED':
            raise ValueError('Required final image lacks matching symbols')
    result = {'status': 'PASS_WITH_COVERAGE_GAPS' if any(i['symbol_status'] != 'MATCHED' for i in current) else 'PASS',
              'kind': manifest['kind'], 'identity': manifest['identity'], 'source': manifest['source'],
              'images': current, 'symbolication': 'NOT_TESTED: backend verification is separate'}
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(f'PASS: {len(current)} final image UUIDs/hashes inventoried; required dSYMs match')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    a = commands.add_parser('archive')
    a.add_argument('--app', type=Path, required=True)
    a.add_argument('--symbols', type=Path, action='append', required=True)
    a.add_argument('--output', type=Path, required=True)
    a.add_argument('--repo', type=Path, required=True)
    a.add_argument('--kind', choices=['acceptance', 'normal-release', 'delivery'], required=True)
    a.add_argument('--require', action='append', default=[])
    v = commands.add_parser('verify')
    v.add_argument('--app', type=Path, required=True)
    v.add_argument('--archive', type=Path, required=True)
    v.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    (archive if args.command == 'archive' else verify)(args)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        print(f'Symbol gate failed: {error}', file=sys.stderr)
        sys.exit(1)
