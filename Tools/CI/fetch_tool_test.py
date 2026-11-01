import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
from tempfile import TemporaryDirectory
import unittest
import zipfile

from fetch_tool import install


class ToolInstallationTests(unittest.TestCase):
    def fixture(self, extra=None, missing=False):
        files = {'tool/bin/tool': b'#!/bin/sh\ncat "$(dirname "$0")/../share/SettingPresets/base.yml"\n',
                 'tool/share/SettingPresets/base.yml': b'complete presets\n'}
        if missing:
            files.pop('tool/share/SettingPresets/base.yml')
        files.update(extra or {})
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, 'w') as archive:
            for name, value in files.items():
                archive.writestr(name, value)
        data = buffer.getvalue()
        entry = dict(sha256=hashlib.sha256(data).hexdigest(), format='zip', member='tool/bin/tool',
                     bundle=dict(prefix='tool', executable='bin/tool',
                                 requiredFiles=['bin/tool', 'share/SettingPresets/base.yml']))
        return entry, data

    def testRuntimeLayoutSurvivesRelocationAndReinstallation(self):
        entry, data = self.fixture()
        with TemporaryDirectory(prefix='tool fixture ') as directory:
            root = Path(directory)
            executable = install('fixture', root / 'original', entry, data, '1')
            self.assertEqual(subprocess.check_output([executable], text=True), 'complete presets\n')
            self.assertEqual(install('fixture', root / 'original', entry, data, '1'), executable)
            shutil.move(root / 'original', root / 'moved folder')
            self.assertEqual(subprocess.check_output([root / 'moved folder/fixture'], text=True), 'complete presets\n')
            record = json.loads((root / 'moved folder/fixture-download.json').read_text())
            self.assertIn('share/SettingPresets/base.yml', record['runtimeFiles'])

    def testMissingResourcesAndBadDigestDoNotReplaceExistingTool(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            existing = root / 'fixture'
            existing.write_bytes(b'keep existing tool')
            for missing in [True, False]:
                entry, data = self.fixture(missing=missing)
                if not missing:
                    entry['sha256'] = '0' * 64
                with self.assertRaises(RuntimeError):
                    install('fixture', root, entry, data, '1')
                self.assertEqual(existing.read_bytes(), b'keep existing tool')

    def testTraversalAndChangedInstalledResourceAreRejected(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            entry, data = self.fixture({'tool/../escape': b'reject'})
            with self.assertRaises(RuntimeError):
                install('fixture', root, entry, data, '1')
            entry, data = self.fixture()
            install('fixture', root, entry, data, '1')
            package = root / ('fixture-' + entry['sha256'][:12])
            (package / 'share/SettingPresets/base.yml').write_text('changed')
            with self.assertRaises(RuntimeError):
                install('fixture', root, entry, data, '1')

    def testStandaloneZipToolRetainsItsInterface(self):
        entry, data = self.fixture()
        entry.pop('bundle')
        with TemporaryDirectory() as directory:
            executable = install('fixture', Path(directory), entry, data, '1')
            with zipfile.ZipFile(io.BytesIO(data)) as archive:
                self.assertEqual(executable.read_bytes(), archive.read(entry['member']))
            self.assertTrue(executable.stat().st_mode & 0o111)
