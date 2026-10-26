#!/usr/bin/env python3
"""Check tracked script/JSON syntax and fully pinned, credential-free CI workflows."""
import argparse
import ast
import json
from pathlib import Path
import re
import subprocess

from run_core import ROOT


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--actionlint', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    report = dict(schema=1, status='failed', files=[], commands=[])
    try:
        paths = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=ROOT).decode().split('\0')
        paths = sorted(set(p for p in paths if p))
        with (args.output / 'checks.log').open('w') as log:
            def run(argv):
                report['commands'].append([str(x) for x in argv])
                subprocess.run(argv, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=60)
            for relative in paths:
                path = ROOT / relative
                suffix = path.suffix
                if suffix not in ('.py', '.json', '.js', '.cjs', '.mjs', '.sh') and path.name != 'Package.resolved':
                    continue
                if path.is_symlink():
                    raise RuntimeError(f'Refusing a symlinked script/input: {relative}')
                if suffix == '.py':
                    ast.parse(path.read_text(), filename=relative)
                elif suffix == '.json' or path.name == 'Package.resolved':
                    json.loads(path.read_text())
                elif suffix in ('.js', '.cjs', '.mjs'):
                    run(['node', '--check', str(path)])
                else:
                    first = path.read_text().splitlines()[0]
                    match = re.fullmatch(r'#!(?:/usr/bin/env |/bin/)(bash|zsh|sh)', first)
                    if not match:
                        raise RuntimeError(f'Unrecognized shell interpreter: {relative}')
                    run(['/bin/' + match[1], '-n', str(path)])
                report['files'].append(relative)
            workflows = sorted((ROOT / '.github/workflows').glob('*.y*ml'))
            if not workflows or not report['files']:
                raise RuntimeError('Static discovery returned no workflows or files')
            for path in workflows:
                text = path.read_text()
                for action in re.findall(r'^\s*(?:-\s*)?uses:\s*(\S+)', text, re.M):
                    if not action.startswith('./') and not re.fullmatch(r'[\w./-]+@[0-9a-f]{40}', action):
                        raise RuntimeError(f'Action must use a full commit SHA: {path.name}: {action}')
                if re.search(r'\bsecrets\s*[.\[]', text):
                    raise RuntimeError(f'Credential-free CI must not reference secrets: {path.name}')
            version = subprocess.check_output([str(args.actionlint), '-version'], text=True).splitlines()[0]
            lock = json.loads((ROOT / 'Tools/CI/tool-downloads.json').read_text())
            if version != lock['actionlint']['version']:
                raise RuntimeError('actionlint version differs from the download lock')
            run([str(args.actionlint), '-shellcheck=', '-pyflakes=', *map(str, workflows)])
            run(['python3', 'Tools/SourceAudit/scan_release_artifacts.py', 'Tools/CI', '.github/workflows',
                 '--json-output', str(args.output / 'ci-source-scan.json')])
            report.update(status='passed', actionlintVersion=version, workflows=[str(p.relative_to(ROOT)) for p in workflows])
    except Exception as error:
        report['error'] = str(error)
    (args.output / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f"Static: {report['status']}; {len(report['files'])} files; {report.get('error', '')}")
    return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
