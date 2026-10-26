"""Failure-path checks for CI result validation; no product code or credentials."""
import unittest

from test_results import InvalidResults, discovered_tests, xctest_results


def log(cases):
    lines = []
    for name, status in cases:
        lines.append(f"Test Case '-[Fixture.Tests {name}]' started.")
        if status == 'skipped':
            lines.append(f"fixture.swift:1: -[Fixture.Tests {name}] : Test skipped - explicit fixture")
        lines.append(f"Test Case '-[Fixture.Tests {name}]' {status} (0.001 seconds).")
    skips = sum(status == 'skipped' for _, status in cases)
    failures = sum(status == 'failed' for _, status in cases)
    lines += ["Test Suite 'All tests' passed at 2026-10-26 00:00:00.",
              f"Executed {len(cases)} tests, with {skips} tests skipped and {failures} failures (0 unexpected)"]
    return '\n'.join(lines)


class ResultValidationTests(unittest.TestCase):
    def check(self, text=None, discovered=None, skips=None, code=0):
        return xctest_results(text if text is not None else log([('testOne', 'passed')]),
                              {'Fixture.Tests/testOne'} if discovered is None else discovered,
                              {} if skips is None else skips, code)

    def test_complete_pass(self):
        self.assertEqual(self.check()['passed'], 1)

    def test_discovery_ignores_build_noise(self):
        self.assertEqual(discovered_tests('Building for production...\nFixture.Tests/testOne\n'), {'Fixture.Tests/testOne'})

    def test_empty_and_duplicate_discovery_fail(self):
        for value in ['', 'Fixture.Tests/testOne\nFixture.Tests/testOne']:
            with self.assertRaises(InvalidResults):
                discovered_tests(value)

    def test_process_failure_cannot_be_overridden_by_passed_output(self):
        with self.assertRaises(InvalidResults): self.check(code=1)

    def test_test_failure_cannot_be_overridden_by_zero_exit(self):
        with self.assertRaises(InvalidResults): self.check(log([('testOne', 'failed')]))

    def test_unrun_discovered_test_fails(self):
        with self.assertRaises(InvalidResults): self.check(discovered={'Fixture.Tests/testOne', 'Fixture.Tests/testTwo'})

    def test_duplicate_completion_fails(self):
        with self.assertRaises(InvalidResults): self.check(log([('testOne', 'passed'), ('testOne', 'passed')]))

    def test_truncated_summary_fails(self):
        with self.assertRaises(InvalidResults): self.check(log([('testOne', 'passed')]).split("Test Suite")[0])

    def test_aggregate_mismatch_fails(self):
        with self.assertRaises(InvalidResults): self.check(log([('testOne', 'passed')]).replace('Executed 1 tests', 'Executed 2 tests'))

    def test_new_skip_and_changed_reason_fail(self):
        for policy in [{}, {'Fixture.Tests/testOne': 'different reason'}]:
            with self.assertRaises(InvalidResults): self.check(log([('testOne', 'skipped')]), skips=policy)

    def test_all_skipped_fails(self):
        with self.assertRaises(InvalidResults): self.check(log([('testOne', 'skipped')]), skips={'Fixture.Tests/testOne': 'explicit fixture'})

    def test_stale_skip_entry_fails(self):
        with self.assertRaises(InvalidResults): self.check(skips={'Fixture.Tests/testMissing': 'explicit fixture'})

    def test_declared_skip_retains_reason(self):
        result = self.check(log([('testOne', 'passed'), ('testTwo', 'skipped')]),
                            {'Fixture.Tests/testOne', 'Fixture.Tests/testTwo'}, {'Fixture.Tests/testTwo': 'explicit fixture'})
        self.assertEqual(result['skipped'], 1)
        self.assertEqual(result['cases'][1]['reason'], 'explicit fixture')


if __name__ == '__main__':
    unittest.main()
