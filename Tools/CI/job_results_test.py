import unittest

from check_jobs import REQUIRED, validate


class JobResultTests(unittest.TestCase):
    def success(self):
        return {name: {'result': 'success'} for name in REQUIRED}

    def test_all_jobs_must_succeed(self):
        self.assertEqual(set(validate(self.success())), REQUIRED)

    def test_failure_cancel_skip_and_unknown_cannot_pass(self):
        for status in ['failure', 'cancelled', 'skipped', 'timed_out', '', None]:
            needs = self.success(); needs['core']['result'] = status
            with self.subTest(status=status), self.assertRaises(ValueError): validate(needs)

    def test_empty_missing_or_extra_job_is_not_success(self):
        missing = self.success(); del missing['app']
        extra = self.success(); extra['unexpected'] = {'result': 'success'}
        for needs in [{}, missing, extra, [], None]:
            with self.assertRaises(ValueError): validate(needs)
