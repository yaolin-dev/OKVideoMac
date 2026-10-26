#!/usr/bin/env python3
"""Run credential-free Python suites with nonempty discovery and no allowed skips."""
import argparse
import importlib.util
import json
from pathlib import Path
import sys
import time
import unittest
import xml.etree.ElementTree as ET

from run_core import ROOT


class RecordedResult(unittest.TextTestResult):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.cases = []
        self.current = None

    def startTest(self, test):
        super().startTest(test)
        self.current = dict(id=test.id(), status='incomplete')
        self.started = time.monotonic()

    def stopTest(self, test):
        self.current['seconds'] = round(time.monotonic() - self.started, 6)
        self.cases.append(self.current)
        self.current = None
        super().stopTest(test)

    def record_problem(self, test, status, reason):
        # Class/module fixtures can report errors or skips without startTest.
        if self.current is None:
            self.cases.append(dict(id=test.id(), status=status, reason=reason, seconds=0))
        else:
            self.current.update(status=status, reason=reason)

    def addSuccess(self, test):
        if self.current['status'] == 'incomplete':
            self.current['status'] = 'passed'
        super().addSuccess(test)

    def addFailure(self, test, err):
        self.record_problem(test, 'failed', self._exc_info_to_string(err, test))
        super().addFailure(test, err)

    def addError(self, test, err):
        self.record_problem(test, 'error', self._exc_info_to_string(err, test))
        super().addError(test, err)

    def addSkip(self, test, reason):
        self.record_problem(test, 'skipped', reason)
        super().addSkip(test, reason)

    def addSubTest(self, test, subtest, err):
        if err:
            self.record_problem(test, 'failed', self._exc_info_to_string(err, test))
        super().addSubTest(test, subtest, err)


def identities(suite):
    for test in suite:
        if isinstance(test, unittest.TestSuite):
            yield from identities(test)
        else:
            yield test.id()


def validate(result, discovered):
    actual = [case['id'] for case in result.cases]
    if (not discovered or len(discovered) != len(set(discovered)) or sorted(actual) != sorted(discovered)
            or result.testsRun != len(discovered) or not result.wasSuccessful()
            or result.skipped or result.expectedFailures or result.unexpectedSuccesses
            or any(case['status'] != 'passed' for case in result.cases)):
        raise RuntimeError('Python discovery/results incomplete, empty, failed or skipped; see tests.log')


def load_suite(name):
    loader = unittest.TestLoader()
    if name == 'crash-configuration':
        path = ROOT / 'Tools/CrashIntegration/test-release-crash-configuration.py'
        spec = importlib.util.spec_from_file_location('ci_crash_configuration', path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return loader.loadTestsFromModule(module)
    folder, pattern = ('Tools/SourceAudit', 'test_*.py') if name == 'audit' else ('Tools/CI', '*_test.py')
    return loader.discover(str(ROOT / folder), pattern=pattern)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--suite', choices=['audit', 'crash-configuration', 'ci'], required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    report = dict(schema=1, suite=args.suite, status='failed', pythonVersion=sys.version)
    try:
        if sys.flags.optimize:
            raise RuntimeError('Optimized Python would disable assertion gates')
        suite = load_suite(args.suite)
        discovered = list(identities(suite))
        report['discovered'] = discovered
        with (args.output / 'tests.log').open('w') as log:
            result = unittest.TextTestRunner(stream=log, verbosity=2, resultclass=RecordedResult).run(suite)
        report.update(total=result.testsRun, passed=sum(case['status'] == 'passed' for case in result.cases),
                      failed=len(result.failures), errors=len(result.errors), skipped=len(result.skipped), cases=result.cases)
        xml = ET.Element('testsuite', name=args.suite, tests=str(len(result.cases)),
                         failures=str(sum(case['status'] == 'failed' for case in result.cases)),
                         errors=str(sum(case['status'] not in {'passed', 'failed', 'skipped'} for case in result.cases)),
                         skipped=str(sum(case['status'] == 'skipped' for case in result.cases)))
        for case in result.cases:
            node = ET.SubElement(xml, 'testcase', name=case['id'], time=str(case['seconds']))
            if case['status'] != 'passed':
                tag = {'skipped': 'skipped', 'failed': 'failure'}.get(case['status'], 'error')
                ET.SubElement(node, tag).text = case.get('reason', case['status'])
        ET.indent(xml)
        ET.ElementTree(xml).write(args.output / 'junit.xml', encoding='utf-8', xml_declaration=True)
        validate(result, discovered)
        report['status'] = 'passed'
    except Exception as error:
        report['error'] = str(error)
    (args.output / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f"{args.suite}: {report['status']}; {report.get('total', 0)} tests; {report.get('error', '')}")
    return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
