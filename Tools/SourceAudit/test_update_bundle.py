import base64
import unittest
from approved_inventory import expected_paths, require_approved
from verify_update_bundle import validate_configuration

class UpdateBundleTests(unittest.TestCase):
    def config(self):
        return {'SUAutomaticallyUpdate':False,'SUAllowsAutomaticUpdates':False,
                'SUScheduledCheckInterval':86400,'SUEnableSystemProfiling':False,
                'SUVerifyUpdateBeforeExtraction':True,'SURequireSignedFeed':True,
                'SUSignedFeedFailureExpirationInterval':0,
                'OKUpdateChannel':'stable','SUFeedURL':'https://example.org/appcast.xml',
                'SUPublicEDKey':base64.b64encode(bytes(32)).decode()}
    def test_exact_inventory_rejects_same_count_substitution(self):
        paths=expected_paths()
        changed=set(paths); changed.remove('Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate')
        changed.add('Contents/Helpers/unknown')
        with self.assertRaises(SystemExit): require_approved(changed)
        self.assertEqual(require_approved(paths),34)
    def test_missing_or_extra_executable_fails(self):
        paths=expected_paths()
        with self.assertRaises(SystemExit): require_approved(paths|{'Contents/MacOS/unapproved'})
        with self.assertRaises(SystemExit): require_approved(paths-{'Contents/MacOS/OKVideoMac'})
    def test_every_policy_flag_is_required(self):
        config=self.config(); validate_configuration(config)
        for key in ('SUAllowsAutomaticUpdates','SUAutomaticallyUpdate','SUEnableSystemProfiling',
                    'SUVerifyUpdateBeforeExtraction','SURequireSignedFeed'):
            changed=dict(config); changed[key]=not changed[key]
            with self.assertRaises(ValueError): validate_configuration(changed)
        config['SUSignedFeedFailureExpirationInterval']=20
        with self.assertRaises(ValueError): validate_configuration(config)
    def test_http_requires_explicit_loopback_channel(self):
        config=self.config(); config['SUFeedURL']='http://127.0.0.1:38473/appcast.xml'
        with self.assertRaises(ValueError): validate_configuration(config)
        config['OKUpdateChannel']='local-test'; validate_configuration(config)
        config['SUFeedURL']='http://192.168.0.2:38473/appcast.xml'
        with self.assertRaises(ValueError): validate_configuration(config)
    def test_automatic_checks_cannot_skip_consent(self):
        config=self.config(); config['SUEnableAutomaticChecks']=True
        with self.assertRaises(ValueError): validate_configuration(config)
    def test_bad_public_key_is_rejected(self):
        config=self.config(); config['SUPublicEDKey']='AAAA'
        with self.assertRaises(ValueError): validate_configuration(config)

    def test_distribution_requires_stable_channel_but_local_builds_remain_supported(self):
        config=self.config()
        validate_configuration(config, require_stable=True)
        local=dict(config, OKUpdateChannel='local-test', SUFeedURL='http://127.0.0.1:38473/appcast.xml')
        unconfigured=dict(config, OKUpdateChannel='unconfigured', SUFeedURL='', SUPublicEDKey='')
        for other in (local, unconfigured):
            validate_configuration(other)
            with self.assertRaises(ValueError): validate_configuration(other, require_stable=True)
