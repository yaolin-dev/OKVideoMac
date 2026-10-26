#!/usr/bin/env python3
"""Run the complete account-free Core/Persistence suite in an explicit configuration."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import time

from test_results import discovered_tests, xctest_results, write_junit

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / 'OKVideoMac/macOS/OKVideoMac/Packages/OKVideoKit'


def command(args, log: Path, timeout: int) -> int:
    with log.open('w') as output:
        process = subprocess.Popen(args, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            return process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            return 124


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--configuration', choices=('debug', 'release'), required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--scratch-path', type=Path, required=True)
    parser.add_argument('--jobs', type=int, default=2)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    report = dict(schema=1, suite='Core/Persistence', configuration=args.configuration, status='failed',
                  platform=platform.platform(), architecture=platform.machine(), commands=[])
    started = time.monotonic()
    try:
        report['sourceCommit'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
        report['swiftVersion'] = subprocess.check_output(['swift', '--version'], text=True, stderr=subprocess.STDOUT).strip()
        report['xcodeVersion'] = subprocess.check_output(['xcodebuild', '-version'], text=True).strip()
        common = ['swift', 'test', '--package-path', str(PACKAGE), '--scratch-path', str(args.scratch_path),
                  '--configuration', args.configuration, '--jobs', str(args.jobs), '--disable-sandbox']
        discover = common + ['list', '--enable-xctest', '--disable-swift-testing']
        report['commands'].append(discover)
        print(f"Building/discovering Core/Persistence ({args.configuration})", flush=True)
        code = command(discover, args.output / 'discovery.log', 1200)
        if code:
            raise RuntimeError(f"Build/discovery failed with exit {code}; see discovery.log")
        tests = discovered_tests((args.output / 'discovery.log').read_text(errors='replace'))
        (args.output / 'discovered-tests.json').write_text(json.dumps(sorted(tests), indent=2) + '\n')
        run = common + ['--skip-build', '--no-parallel', '--enable-xctest', '--disable-swift-testing']
        report['commands'].append(run)
        print(f"Running {len(tests)} discovered tests ({args.configuration})", flush=True)
        code = command(run, args.output / 'tests.log', 600)
        report['testExitCode'] = code
        log = args.output / 'tests.log'
        report['testLogSHA256'] = hashlib.sha256(log.read_bytes()).hexdigest()
        policy = json.loads((Path(__file__).parent / 'core-allowed-skips.json').read_text())
        result = xctest_results(log.read_text(errors='replace'), tests, policy['allowed_skips'], code)
        report.update(result)
        write_junit(args.output / 'junit.xml', result, f"Core/Persistence ({args.configuration})")
        report['status'] = 'passed'
    except Exception as error:
        report['error'] = str(error)
        print(f"FAIL: {error}", flush=True)
    finally:
        report['elapsedSeconds'] = round(time.monotonic() - started, 3)
        (args.output / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
        text = f"### Core/Persistence — {args.configuration}\n\nStatus: **{report['status']}**\n\n"
        if report['status'] == 'passed':
            text += f"{report['passed']} passed / {report['skipped']} declared skips / {report['failed']} failed; {report['total']} discovered and completed.\n"
        else:
            text += f"{report.get('error', 'Missing results')}\n"
        text += '\nSee the retained command logs, toolchain metadata and individual results.\n'
        (args.output / 'summary.md').write_text(text)
        if os.environ.get('GITHUB_STEP_SUMMARY'):
            with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as output:
                output.write(text)
        print(text, flush=True)
    return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
