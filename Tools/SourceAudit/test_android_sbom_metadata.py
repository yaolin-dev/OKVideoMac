"""Reject stale aggregate versions even when Maven and executable inventories match."""
import copy
from pathlib import Path
import tempfile
import unittest
from generate_sbom import android_inventory, android_bridge_version, spdx, cyclonedx
from verify_sbom import verify_android_bridge_documents


class AndroidSBOMMetadataTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.lock = self.root / "gradle.lockfile"
        self.lock.write_text("# synthetic empty Maven graph\nempty=releaseRuntimeClasspath\n")
        self.gradle = self.root / "build.gradle"
        self.gradle.write_text('versionName = "9.8.7"\n')
        self.apk = self.root / "test.apk"
        self.apk.write_bytes(b"synthetic APK identity")
        self.items = android_inventory(self.lock, self.root / "cache", self.apk)
        self.spdx = spdx("test", "9.8.7", self.items, "2026-11-04T00:00:00Z", "bridge")
        self.cdx = cyclonedx("test", "9.8.7", self.items, "2026-11-04T00:00:00Z", "bridge")

    def verify(self):
        verify_android_bridge_documents(self.spdx, self.cdx, "9.8.7", self.apk)

    def test_current_source_version_drives_aggregate_and_both_formats(self):
        self.assertEqual(self.items[0]["version"], "9.8.7")
        self.assertEqual(self.items[0]["purl"], "pkg:generic/OKVideoMac-AndroidDexBridge@9.8.7")
        self.verify()

    def test_later_bridge_bump_changes_inventory_without_generator_edits(self):
        self.gradle.write_text('versionName = "9.8.8"\n')
        item = android_inventory(self.lock, self.root / "cache", self.apk)[0]
        self.assertEqual(item["version"], "9.8.8")
        self.assertTrue(item["purl"].endswith("@9.8.8"))

    def test_legacy_spdx_version_is_rejected(self):
        self.spdx["packages"][0]["versionInfo"] = "0.3.14"
        with self.assertRaisesRegex(SystemExit, "SPDX version"):
            self.verify()

    def test_legacy_spdx_package_reference_is_rejected(self):
        self.spdx["packages"][0]["externalRefs"][0]["referenceLocator"] = "pkg:generic/OKVideoMac-AndroidDexBridge@0.3.14"
        with self.assertRaisesRegex(SystemExit, "SPDX version"):
            self.verify()

    def test_legacy_cyclonedx_metadata_is_rejected(self):
        self.cdx["metadata"]["component"]["version"] = "0.3.14"
        with self.assertRaisesRegex(SystemExit, "CycloneDX version"):
            self.verify()

    def test_stale_package_references_are_rejected(self):
        original = copy.deepcopy(self.cdx)
        for field in ["purl", "bom-ref", "version"]:
            with self.subTest(field=field):
                self.cdx = copy.deepcopy(original)
                self.cdx["components"][0][field] = "stale"
                with self.assertRaisesRegex(SystemExit, "CycloneDX version"):
                    self.verify()

    def test_changed_apk_cannot_reuse_published_metadata(self):
        self.apk.write_bytes(b"different synthetic APK")
        with self.assertRaisesRegex(SystemExit, "SPDX version, purl or APK hash"):
            self.verify()

    def test_cyclonedx_apk_hash_is_checked_independently(self):
        self.cdx["components"][0]["hashes"][0]["content"] = "0" * 64
        with self.assertRaisesRegex(SystemExit, "CycloneDX version"):
            self.verify()

    def test_missing_and_duplicate_aggregates_are_rejected(self):
        for key, document in [("packages", self.spdx), ("components", self.cdx)]:
            original = copy.deepcopy(document[key])
            for values in [original[1:], [original[0], *original]]:
                with self.subTest(key=key, count=len(values)):
                    document[key] = values
                    with self.assertRaisesRegex(SystemExit, "missing or duplicated"):
                        self.verify()
            document[key] = original

    def test_missing_ambiguous_and_nonliteral_versions_fail_closed(self):
        for text in ['', 'versionName = generatedVersion\n',
                     'versionName = "9.8.7"\nversionName = "9.8.8"\n']:
            with self.subTest(text=text):
                self.gradle.write_text(text)
                with self.assertRaisesRegex(SystemExit, "one literal"):
                    android_bridge_version(self.lock)


if __name__ == "__main__":
    unittest.main()
