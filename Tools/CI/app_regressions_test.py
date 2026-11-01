import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from run_app_regressions import selected_tests, source_fingerprint, validate_results, validate_test_host


class AppRegressionReportTests(unittest.TestCase):
    def log(self, status='passed', identity='FlowTests testClose', count=1):
        return (f"Test Case '-[OKVideoMacTests.{identity}]' started.\n"
                f"Test Case '-[OKVideoMacTests.{identity}]' {status} (0.001 seconds).\n"
                "Test Suite 'Selected tests' passed at now.\n"
                f"Executed {count} tests, with 0 failures (0 unexpected)\n"
                "** TEST EXECUTE SUCCEEDED **\n")

    def testSelectedSuiteMustMatchEveryContractIdentity(self):
        result = validate_results(self.log(), ['FlowTests/testClose'], 0)
        self.assertEqual((result['total'], result['passed'], result['skipped']), (1, 1, 0))
        with self.assertRaises(ValueError):
            validate_results(self.log(), ['FlowTests/testClose', 'FlowTests/testResume'], 0)

    def testMissingRenamedOrUnexpectedCaseFails(self):
        for identity in ['FlowTests testRenamed', 'OtherTests testClose']:
            with self.assertRaises(ValueError):
                validate_results(self.log(identity=identity), ['FlowTests/testClose'], 0)

    def testSkippedFailedOrIncompleteExecutionNeverPasses(self):
        for log in [self.log('skipped'), self.log('failed'), self.log().replace('** TEST EXECUTE SUCCEEDED **', ''),
                    self.log().replace("Test Suite 'Selected tests' passed", "Test Suite 'Selected tests' failed")]:
            with self.assertRaises(ValueError):
                validate_results(log, ['FlowTests/testClose'], 0)
        with self.assertRaises(ValueError):
            validate_results(self.log(), ['FlowTests/testClose'], 65)

    def testRetryDuplicatesAndContradictoryTotalsFail(self):
        for log in [self.log() + self.log(), self.log(count=2)]:
            with self.assertRaises(ValueError):
                validate_results(log, ['FlowTests/testClose'], 0)

    def testBothGroupsMustBeNonemptyAndDisjoint(self):
        plan = dict(schema=1, target='OKVideoMacTests', groups={
            'logic': ['FlowTests/testClose'], 'desktop': ['PanelTests/testOutsideClick']})
        self.assertEqual(len(selected_tests(plan, 'all')), 2)
        for entries in [[], ['FlowTests/testClose'], ['invalid']]:
            plan['groups']['desktop'] = entries
            with self.assertRaises(ValueError):
                selected_tests(plan, 'all')

    def testSourceAndTestChangesInvalidateReusableBuildButOutputsDoNot(self):
        with TemporaryDirectory() as directory:
            project = Path(directory)
            (project / 'project.yml').write_text('version: 1')
            (project / 'OKVideoMac.xcodeproj').mkdir()
            (project / 'OKVideoMac.xcodeproj/project.pbxproj').write_text('project')
            (project / 'App').mkdir()
            source = project / 'App/State.swift'
            source.write_text('let version = 1')
            (project / 'Tests').mkdir()
            test = project / 'Tests/FlowTests.swift'
            test.write_text('test version 1')
            first = source_fingerprint(project)
            source.write_text('let version = 2')
            second = source_fingerprint(project)
            self.assertNotEqual(first, second)
            test.write_text('test version 2')
            third = source_fingerprint(project)
            self.assertNotEqual(second, third)
            (project / 'Build').mkdir()
            (project / 'Build/Generated.swift').write_text('build output')
            self.assertEqual(third, source_fingerprint(project))

    def testPublicOrCachedDifferentHostIsRejectedBeforeLaunch(self):
        info = {'CFBundleIdentifier': 'com.okvideomac.OKVideoMac.regression'}
        validate_test_host(info, {'TestHostBundleIdentifier': info['CFBundleIdentifier']})
        with self.assertRaises(ValueError):
            validate_test_host(info, {'TestHostBundleIdentifier': 'com.okvideomac.OKVideoMac.old'})
        with self.assertRaises(ValueError):
            validate_test_host({'CFBundleIdentifier': 'com.okvideomac.OKVideoMac'},
                               {'TestHostBundleIdentifier': 'com.okvideomac.OKVideoMac'})


if __name__ == '__main__':
    unittest.main()
