#!/usr/bin/env python3
"""Upload only final-package-matched dSYMs; keep auth and source bundles out of artifacts."""
import argparse
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile


def configuration(path):
    info = path.lstat()
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
            or info.st_mode & 0o077 or info.st_size > 8192):
        raise ValueError('Symbol config must be an owner-only regular file, at most 8 KiB')
    values = {}
    for line in path.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        key, separator, value = line.partition('=')
        if not separator or key in values:
            raise ValueError('Invalid or duplicate symbol configuration key')
        values[key] = value.strip().strip('\"\'')
    if set(values) != {'SENTRY_ORG', 'SENTRY_PROJECT', 'SENTRY_AUTH_TOKEN'}:
        raise ValueError('Unexpected symbol configuration fields')
    if any(not re.fullmatch(r'[A-Za-z0-9_-]+', values[k]) for k in ['SENTRY_ORG', 'SENTRY_PROJECT']):
        raise ValueError('Invalid Sentry project identity')
    if not values['SENTRY_AUTH_TOKEN'] or any(c.isspace() for c in values['SENTRY_AUTH_TOKEN']):
        raise ValueError('Invalid Sentry auth token')
    return values


def upload_command(cli, archive, verified):
    symbols = [s for image in verified['images'] for s in image['symbols']]
    if not symbols:
        raise ValueError('No matched dSYMs')
    paths = sorted({str((archive / s['dwarf']).resolve()) for s in symbols})
    if any(not Path(p).is_relative_to(archive.resolve() / 'symbols') for p in paths):
        raise ValueError('Symbol escaped its verified archive')
    ids = sorted({s['uuid'].lower() for s in symbols})
    command = [str(cli), 'debug-files', 'upload', '--type', 'dsym', '--no-sources', '--no-zips',
               '--wait-for', '300', '--require-all']
    for uuid in ids:
        command += ['--id', uuid]
    return command + paths, ids


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--cli', type=Path, required=True)
    parser.add_argument('--receipt', type=Path, required=True)
    args = parser.parse_args()
    if args.config.resolve().is_relative_to(Path(__file__).resolve().parents[4]):
        raise ValueError('Symbol config must be outside the source checkout')
    config = configuration(args.config)
    with tempfile.TemporaryDirectory(prefix='OKVideoMac-SymbolPreflight-') as temp:
        verification = Path(temp) / 'verified.json'
        subprocess.run(['python3', str(Path(__file__).with_name('crash-symbols.py')), 'verify',
            '--app', str(args.app), '--archive', str(args.archive), '--output', str(verification)], check=True)
        verified = json.loads(verification.read_text())
    command, ids = upload_command(args.cli, args.archive, verified)
    env = dict(os.environ, **config, SENTRY_URL='https://sentry.io/', SENTRY_LOG_LEVEL='warn')
    result = subprocess.run(command, env=env, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=420)
    log = result.stdout.replace(config['SENTRY_AUTH_TOKEN'], '[REDACTED]')
    args.receipt.parent.mkdir(parents=True, exist_ok=True)
    args.receipt.with_suffix('.log').write_text(log)
    receipt = {'status': 'processed' if result.returncode == 0 else 'failed',
        'org': config['SENTRY_ORG'], 'project': config['SENTRY_PROJECT'],
        'identity': verified['identity'], 'debugIDs': ids, 'sourceBundlesUploaded': False,
        'exitCode': result.returncode, 'backendEventSymbolication': 'separate verification required'}
    args.receipt.write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))
    if result.returncode:
        raise SystemExit(result.returncode)


if __name__ == '__main__':
    main()
