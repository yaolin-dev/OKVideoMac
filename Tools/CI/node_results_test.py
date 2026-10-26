import unittest

from test_results import InvalidResults, node_results


GOOD = '''<testsuites><testcase name="real test" classname="test"/>
<!-- tests 1 --><!-- suites 0 --><!-- pass 1 --><!-- fail 0 --><!-- cancelled 0 -->
<!-- skipped 0 --><!-- todo 0 --></testsuites>'''


class NodeResultTests(unittest.TestCase):
    def test_complete_success(self):
        self.assertEqual(node_results(GOOD, 'fixture.test.js', 0)['passed'], 1)

    def test_nonzero_exit_cannot_pass(self):
        with self.assertRaises(InvalidResults): node_results(GOOD, 'fixture.test.js', 1)

    def test_empty_file_is_not_a_test(self):
        with self.assertRaises(InvalidResults):
            node_results(GOOD.replace('real test', '/tmp/fixture.test.js'), 'fixture.test.js', 0)

    def test_failure_skip_and_todo_are_rejected(self):
        for fragment in ['<failure/>', '<error/>', '<skipped/>']:
            with self.assertRaises(InvalidResults):
                node_results(GOOD.replace('</testsuites>', fragment + '</testsuites>'), 'fixture.test.js', 0)
        with self.assertRaises(InvalidResults):
            node_results(GOOD.replace('todo 0', 'todo 1'), 'fixture.test.js', 0)

    def test_missing_mismatched_and_duplicate_aggregates_fail(self):
        for text in [GOOD.replace('<!-- tests 1 -->', ''), GOOD.replace('tests 1', 'tests 2'),
                     GOOD.replace('</testsuites>', '<!-- tests 1 --></testsuites>')]:
            with self.assertRaises(InvalidResults): node_results(text, 'fixture.test.js', 0)

    def test_empty_or_duplicate_cases_fail(self):
        for text in [GOOD.replace('<testcase name="real test" classname="test"/>', ''),
                     GOOD.replace('</testsuites>', '<testcase name="real test"/></testsuites>')]:
            with self.assertRaises(InvalidResults): node_results(text, 'fixture.test.js', 0)

    def test_subtest_parent_counts_but_describe_container_does_not(self):
        nested = GOOD.replace('<testcase name="real test" classname="test"/>',
                              '<testsuite name="parent" tests="1"><testcase name="child"/></testsuite>')
        parent = nested.replace('tests 1', 'tests 2').replace('pass 1', 'pass 2')
        self.assertEqual(node_results(parent, 'fixture.test.js', 0)['total'], 2)
        self.assertEqual(node_results(nested.replace('suites 0', 'suites 1'), 'fixture.test.js', 0)['total'], 1)
        with self.assertRaises(InvalidResults): node_results(nested, 'fixture.test.js', 0)
        with self.assertRaises(InvalidResults):
            node_results(parent.replace('tests="1"', 'tests="2"'), 'fixture.test.js', 0)
