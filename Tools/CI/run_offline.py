#!/usr/bin/env python3
"""Run offline audit, crash/symbol gates and static checks with synthetic fixtures."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time

from run_core import ROOT, command


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--work-dir', type=Path, required=True)
    parser.add_argument('--actionlint', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    args.work_dir.mkdir(parents=True, exist_ok=True)
    report = dict(schema=1, suite='Offline audits and static checks', status='failed', stages=[])
    started = time.monotonic()
    try:
        if sys.flags.optimize:
            raise RuntimeError('Do not disable Python assertions')
        report['sourceCommit'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
        def run(name, argv, timeout=300):
            item = dict(name=name, command=[str(x) for x in argv])
            report['stages'].append(item)
            item['exitCode'] = command(item['command'], args.output / (name + '.log'), timeout)
            if item['exitCode']:
                raise RuntimeError(f'{name} failed with exit {item["exitCode"]}; see {name}.log')
        launcher = args.work_dir / 'AcceptanceLauncher'
        run('compile-fixture-launcher', ['xcrun', 'swiftc', '-O', '-parse-as-library',
            'Tools/SourceAudit/AcceptanceLauncher.swift', '-o', launcher])
        run('adhoc-fixture-launcher', ['/usr/bin/codesign', '--force', '--sign', '-', launcher])
        os.environ['OKVIDEO_ACCEPTANCE_TEST_LAUNCHER'] = str(launcher)
        for suite in ['ci', 'audit', 'crash-configuration']:
            run(suite, [sys.executable, 'Tools/CI/run_python.py', '--suite', suite, '--output', args.output / suite])
            result = json.loads((args.output / suite / 'summary.json').read_text())
            if result['status'] != 'passed' or result['total'] <= 0 or result['skipped']:
                raise RuntimeError(f'{suite} machine report failed validation')
        run('symbols', [sys.executable, 'Tools/CrashIntegration/test-symbol-archive.py'])
        symbols = json.loads((args.output / 'symbols.log').read_text())
        if symbols.get('status') != 'PASS' or not symbols.get('cases') or len(symbols['cases']) != len(set(symbols['cases'])):
            raise RuntimeError('Symbol test report was empty, duplicated or unsuccessful')
        report['symbolCases'] = len(symbols['cases'])
        run('static', [sys.executable, 'Tools/CI/run_static.py', '--actionlint', args.actionlint, '--output', args.output / 'static'])
        report['status'] = 'passed'
    except Exception as error:
        report['error'] = str(error)
    report['elapsedSeconds'] = round(time.monotonic() - started, 3)
    (args.output / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
    text = f"### Offline audits and static checks\n\nStatus: **{report['status']}**\n\n"
    text += 'All discovered Python tests, native synthetic fixtures, symbol gates and static checks passed. No skips.\n' if report['status'] == 'passed' else report.get('error', 'Missing result') + '\n'
    (args.output / 'summary.md').write_text(text)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as output:
            output.write(text)
    print(text, flush=True)
    return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
