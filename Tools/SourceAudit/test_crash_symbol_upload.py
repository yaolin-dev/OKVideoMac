import importlib.util
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'OKVideoMac/macOS/OKVideoMac/Scripts/upload-crash-symbols.py'
spec = importlib.util.spec_from_file_location('symbol_upload', SCRIPT)
upload = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upload)


class SymbolUploadTests(unittest.TestCase):
    def test_private_config_and_no_secret_in_command(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            config = root / 'symbols.env'
            config.write_text('SENTRY_ORG=okvideo\nSENTRY_PROJECT=okvideomac-macos\nSENTRY_AUTH_TOKEN=secret\n')
            config.chmod(0o600)
            self.assertEqual(upload.configuration(config)['SENTRY_PROJECT'], 'okvideomac-macos')
            command, ids = upload.upload_command(Path('/cli'), root, {'images': [{'symbols': [
                {'uuid': '12345678-1234-1234-1234-123456789ABC', 'dwarf': 'symbols/app.dSYM/Contents/Resources/DWARF/app'}]}]})
            self.assertNotIn('secret', command)
            self.assertIn('--no-sources', command)
            self.assertNotIn('--include-sources', command)
            self.assertEqual(ids, ['12345678-1234-1234-1234-123456789abc'])
            self.assertIn('--require-all', command)
            config.chmod(0o644)
            with self.assertRaises(ValueError): upload.configuration(config)

    def test_source_bundle_path_cannot_escape_archive(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(ValueError):
                upload.upload_command(Path('/cli'), Path(temp), {'images': [{'symbols': [
                    {'uuid': 'uuid', 'dwarf': '../../source.tar.gz'}]}]})

    def test_unexpected_or_linked_config_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            config = root / 'symbols.env'
            config.write_text('SENTRY_ORG=okvideo\nSENTRY_PROJECT=okvideomac-macos\nSENTRY_AUTH_TOKEN=secret\nSENTRY_URL=https://other.invalid\n')
            config.chmod(0o600)
            with self.assertRaises(ValueError): upload.configuration(config)
            linked = root / 'linked.env'
            linked.symlink_to(config)
            with self.assertRaises(ValueError): upload.configuration(linked)


if __name__ == '__main__': unittest.main()
