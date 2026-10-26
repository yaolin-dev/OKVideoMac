#!/usr/bin/env python3
"""Run every Node test file separately and require nonempty, complete JUnit results."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

from run_core import ROOT, command
from test_results import node_results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    report = dict(schema=1, suite='Node', status='failed', files=[])
    started = time.monotonic()
    try:
        report['sourceCommit'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
        report['nodeVersion'] = subprocess.check_output(['node', '--version'], text=True).strip()
        if report['nodeVersion'] != 'v22.23.0':
            raise RuntimeError('CI requires Node 22.23.0; use the pinned setup-node version')
        files = sorted((ROOT / 'OKVideoMac/macOS/OKVideoMac/NodeTests').glob('*.test.js'))
        if not files:
            raise RuntimeError('No Node test files discovered')
        for path in files:
            log = args.output / (path.stem + '.xml')
            argv = ['node', '--test', '--test-reporter=junit', str(path)]
            item = dict(file=str(path.relative_to(ROOT)), command=argv, status='failed')
            report['files'].append(item)
            code = command(argv, log, 120)
            item.update(exitCode=code, logSHA256=hashlib.sha256(log.read_bytes()).hexdigest())
            try:
                item.update(node_results(log.read_text(), path.name, code), status='passed')
            except Exception as error:
                item['error'] = str(error)
            print(f"{item['status']}: {path.name}", flush=True)
        if any(item['status'] != 'passed' for item in report['files']):
            raise RuntimeError('At least one Node file failed result validation; see individual logs')
        report.update(status='passed', total=sum(item['total'] for item in report['files']))
    except Exception as error:
        report['error'] = str(error)
    finally:
        report['elapsedSeconds'] = round(time.monotonic() - started, 3)
        (args.output / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
        text = f"### Node\n\nStatus: **{report['status']}**\n\n"
        text += f"{report['total']} tests passed across {len(report['files'])} files; no skips.\n" if report['status'] == 'passed' else report.get('error', 'Missing result') + '\n'
        (args.output / 'summary.md').write_text(text)
        if os.environ.get('GITHUB_STEP_SUMMARY'):
            with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as output:
                output.write(text)
        print(text, flush=True)
    return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
