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
        suite = unittest.TestSuite([] if behavior == 'empty' else [Fixture()])
        discovered = list(identities(suite))
        result = unittest.TextTestRunner(stream=io.StringIO(), resultclass=RecordedResult).run(suite)
        return result, discovered

    def test_success(self):
        validate(*self.result('pass'))

    def test_empty_skip_failure_and_subtest_failure_rejected(self):
        for behavior in ['empty', 'skip', 'fail', 'subtest']:
            with self.subTest(behavior=behavior), self.assertRaises(RuntimeError):
                validate(*self.result(behavior))

    def test_unexecuted_discovery_rejected(self):
        result, discovered = self.result('pass')
        with self.assertRaises(RuntimeError): validate(result, discovered + ['not.executed'])
