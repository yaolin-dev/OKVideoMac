from copy import deepcopy
import unittest

from run_app import validate_generated_test_configuration


class GeneratedAppTests(unittest.TestCase):
    def fixture(self):
        settings = dict(PRODUCT_NAME='OKVideoMacTests', BUNDLE_LOADER='$(TEST_HOST)',
                        TEST_HOST='$(BUILT_PRODUCTS_DIR)/OKVideoMac.app/Contents/MacOS/OKVideoMac')
        return {'objects': {'target': dict(isa='PBXNativeTarget', name='OKVideoMacTests', buildConfigurationList='list'),
                            'list': dict(buildConfigurations=['debug', 'release']),
                            'debug': dict(name='Debug', buildSettings=deepcopy(settings)),
                            'release': dict(name='Release', buildSettings=deepcopy(settings))}}

    def testBothHostConfigurationsAreRequired(self):
        project = self.fixture()
        self.assertEqual(validate_generated_test_configuration(project), ['Debug', 'Release'])
        project['objects']['list']['buildConfigurations'] = ['debug']
        with self.assertRaises(ValueError):
            validate_generated_test_configuration(project)

    def testMissingPresetsFailBeforeAnyBuild(self):
        for key in ['BUNDLE_LOADER', 'TEST_HOST', 'PRODUCT_NAME']:
            project = self.fixture()
            project['objects']['release']['buildSettings'].pop(key)
            with self.assertRaises(ValueError):
                validate_generated_test_configuration(project)

    def testWrongOrAmbiguousHostCannotPass(self):
        project = self.fixture()
        project['objects']['debug']['buildSettings']['TEST_HOST'] = '/other/App'
        with self.assertRaises(ValueError):
            validate_generated_test_configuration(project)
        project = self.fixture()
        project['objects']['duplicate'] = deepcopy(project['objects']['target'])
        with self.assertRaises(ValueError):
            validate_generated_test_configuration(project)
