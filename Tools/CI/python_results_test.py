import io
import unittest

from run_python import RecordedResult, identities, validate


class PythonResultTests(unittest.TestCase):
    def result(self, behavior):
        class Fixture(unittest.TestCase):
            def runTest(self):
                if behavior == 'skip': self.skipTest('not allowed in CI')
                if behavior == 'fail': self.fail('injected failure')
                if behavior == 'subtest':
                    with self.subTest(value=1): self.assertEqual(1, 2)
                if behavior == 'subtest-skip':
                    with self.subTest(value=1): self.skipTest('subtest skip is not allowed')
        suite = unittest.TestSuite([] if behavior == 'empty' else [Fixture()])
        discovered = list(identities(suite))
        result = unittest.TextTestRunner(stream=io.StringIO(), resultclass=RecordedResult).run(suite)
        return result, discovered

    def test_success(self):
        validate(*self.result('pass'))

    def test_empty_skip_failure_and_subtest_failure_rejected(self):
        for behavior in ['empty', 'skip', 'fail', 'subtest', 'subtest-skip']:
            with self.subTest(behavior=behavior), self.assertRaises(RuntimeError):
                validate(*self.result(behavior))

    def test_unexecuted_discovery_rejected(self):
        result, discovered = self.result('pass')
        with self.assertRaises(RuntimeError): validate(result, discovered + ['not.executed'])

    def fixture_result(self, phase, error):
        class Fixture(unittest.TestCase):
            def runTest(self): pass
        def broken_fixture(cls): raise error
        setattr(Fixture, phase, classmethod(broken_fixture))
        suite = unittest.TestSuite([Fixture()])
        discovered = list(identities(suite))
        result = unittest.TextTestRunner(stream=io.StringIO(), resultclass=RecordedResult).run(suite)
        return result, discovered

    def test_class_fixture_errors_retain_original_diagnostic(self):
        for phase in ['setUpClass', 'tearDownClass']:
            with self.subTest(phase=phase):
                result, discovered = self.fixture_result(phase, RuntimeError('fixture initialization failed'))
                with self.assertRaises(RuntimeError): validate(result, discovered)
                errors = [case for case in result.cases if case['status'] == 'error']
                self.assertEqual(len(errors), 1)
                self.assertIn(phase, errors[0]['id'])
                self.assertIn('fixture initialization failed', errors[0]['reason'])
                self.assertEqual(result.testsRun, 0 if phase == 'setUpClass' else 1)

    def test_class_fixture_skips_are_recorded_and_rejected(self):
        result, discovered = self.fixture_result('setUpClass', unittest.SkipTest('missing fixture'))
        with self.assertRaises(RuntimeError): validate(result, discovered)
        self.assertEqual(result.testsRun, 0)
        self.assertEqual(result.cases[0]['status'], 'skipped')
        self.assertEqual(result.cases[0]['reason'], 'missing fixture')
