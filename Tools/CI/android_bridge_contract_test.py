import importlib.util
from pathlib import Path
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'OKVideoMac/macOS/OKVideoMac/Scripts/check-android-bridge-contract.py'
spec = importlib.util.spec_from_file_location('bridge_contract', SCRIPT)
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)


def host(name='0.3.54', code=66):
    return f'static let bridgeVersion = "{name}"\nstatic let bridgeVersionCode = {code}\n'


def gradle(name='0.3.54', code=66):
    return f'versionName = "{name}"\nversionCode = {code}\n'


class BridgeContractTests(unittest.TestCase):
    def testBuild177MismatchIsRejectedEvenWhenAPKMatchesGradle(self):
        with self.assertRaisesRegex(ValueError, 'host=.*Gradle='):
            contract.validate(host('0.3.53',65), gradle(), '0.3.54', '66')

    def testStalePackagedAPKIsRejected(self):
        with self.assertRaisesRegex(ValueError, 'APK='):
            contract.validate(host(), gradle(), '0.3.53', '65')

    def testVersionNameAndCodeMustBothMatch(self):
        for name,code in [('0.3.54',65), ('0.3.53',66)]:
            with self.assertRaises(ValueError):
                contract.validate(host(), gradle(name,code))

    def testMatchingSourceAndAPKPass(self):
        self.assertEqual(contract.validate(host(), gradle(), '0.3.54', '66'), ('0.3.54',66))
        self.assertEqual(contract.validate(host(), gradle()), ('0.3.54',66))

    def testMissingDuplicateAndPartialInputFailClosed(self):
        for runtime in ['', host()+host()]:
            with self.assertRaises(ValueError): contract.validate(runtime, gradle())
        with self.assertRaises(ValueError): contract.validate(host(), gradle(), '0.3.54')


if __name__ == '__main__': unittest.main()
