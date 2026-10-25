#!/usr/bin/env python3
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import local_acceptance as acceptance
import create_source_release as release


class LocalAcceptanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        (self.repo / "App.swift").write_text("let value = 1\n")
        self.snapshot = self.root / "snapshot"

    def freeze(self):
        with patch.object(acceptance, "selected_files", return_value=["App.swift"]), \
             patch.object(acceptance, "worktree_context", return_value={
                 "branch": "codex/test", "baselineHEAD": "a" * 40,
                 "version": "0.6.1", "build": "101", "trackedModifications": ["App.swift"],
                 "includedUntrackedSource": []}):
            return acceptance.freeze(self.repo, self.snapshot)

    def testFrozenBytesAndUncommittedIdentity(self):
        value = self.freeze()
        self.assertIsNone(value["git_commit"])
        self.assertEqual(value["base_git_commit"], "a" * 40)
        (self.repo / "App.swift").write_text("let value = 2\n")
        self.assertEqual((self.snapshot / "App.swift").read_text(), "let value = 1\n")
        self.assertEqual(acceptance.validate(self.snapshot), value)

    def testPrivateProvenanceBindsPathsButDoesNotEnterSourceArchive(self):
        value = self.freeze()
        private = json.loads((self.root / "snapshot-PRIVATE-PROVENANCE.json").read_text())
        self.assertEqual(private["repositoryRoot"], str(self.repo.resolve()))
        self.assertEqual(private["worktreePath"], str(self.repo.resolve()))
        self.assertEqual(private["branch"], "codex/test")
        self.assertEqual(private["source_sha256"], value["source_sha256"])
        self.assertNotIn(str(self.repo), (self.snapshot / acceptance.MANIFEST).read_text())
        self.assertFalse(value["gitCommitBound"])
        self.assertTrue(value["acceptanceOnly"])
        self.assertFalse(value["publicReleaseEligible"])

    def testMainOrChangedBranchRejectsCapture(self):
        with patch.object(acceptance.subprocess, "check_output", return_value="main"):
            with self.assertRaisesRegex(ValueError, "development branch"):
                acceptance.worktree_context(self.repo, ["App.swift"])
        with patch.object(acceptance, "selected_files", return_value=["App.swift"]), \
             patch.object(acceptance, "worktree_context", side_effect=[
                 {"branch": "codex/a", "baselineHEAD": "a" * 40},
                 {"branch": "codex/b", "baselineHEAD": "a" * 40}]):
            with self.assertRaisesRegex(ValueError, "Worktree changed"):
                acceptance.freeze(self.repo, self.snapshot)

    def testPublicReleaseEligibilityRejects(self):
        self.freeze()
        path = self.snapshot / acceptance.MANIFEST
        value = json.loads(path.read_text())
        value["publicReleaseEligible"] = True
        path.write_text(json.dumps(value))
        with self.assertRaisesRegex(ValueError, "Git provenance"):
            acceptance.validate(self.snapshot)

    def testTamperedBytesReject(self):
        self.freeze()
        (self.snapshot / "App.swift").write_text("tampered")
        with self.assertRaises(ValueError):
            acceptance.validate(self.snapshot)

    def testChangedExecutableModeRejects(self):
        self.freeze()
        (self.snapshot / "App.swift").chmod(0o755)
        with self.assertRaises(ValueError):
            acceptance.validate(self.snapshot)

    def testUnrecordedInputRejectsButBuildOutputIsNotArchived(self):
        self.freeze()
        (self.snapshot / "Injected.swift").write_text("unexpected")
        with self.assertRaises(ValueError):
            acceptance.validate(self.snapshot)
        (self.snapshot / "Injected.swift").unlink()
        (self.snapshot / "build").mkdir()
        (self.snapshot / "build/output").write_text("generated")
        archive = self.root / "source.tar.gz"
        acceptance.archive_snapshot(self.snapshot, archive, "source")
        with tarfile.open(archive) as tar:
            self.assertEqual(tar.getnames(), ["source/App.swift", "source/" + acceptance.MANIFEST])
            self.assertEqual(tar.extractfile("source/App.swift").read(), b"let value = 1\n")

    def testPinnedSDKBuildOutputIsExcludedButAdjacentInputsReject(self):
        self.freeze()
        vendor = self.snapshot / "OKVideoMac/macOS/OKVideoMac/Packages/OKCrashDiagnostics/Vendor"
        sdk = vendor / "CrashReporter.xcframework/macos-arm64/CrashReporter.framework/Versions/A/CrashReporter"
        sdk.parent.mkdir(parents=True)
        sdk.write_bytes(b"generated pinned SDK input")
        self.assertEqual(acceptance.validate(self.snapshot)["kind"], "local-uncommitted-acceptance")
        archive = self.root / "source.tar.gz"
        acceptance.archive_snapshot(self.snapshot, archive, "source")
        with tarfile.open(archive) as tar:
            self.assertEqual(tar.getnames(), ["source/App.swift", "source/" + acceptance.MANIFEST])
        (vendor / "Injected.swift").write_text("unexpected source")
        with self.assertRaisesRegex(ValueError, "Uncaptured file"):
            acceptance.validate(self.snapshot)

    def testManifestInventoryTamperRejects(self):
        self.freeze()
        path = self.snapshot / acceptance.MANIFEST
        value = json.loads(path.read_text())
        value["files"][0]["sha256"] = "0" * 64
        path.write_text(json.dumps(value))
        with self.assertRaises(ValueError):
            acceptance.validate(self.snapshot)

    def testSymlinkAndTraversalReject(self):
        (self.repo / "link").symlink_to(self.repo / "App.swift")
        for relative in ["link", "../repo/App.swift", "/etc/passwd"]:
            with self.assertRaises(ValueError):
                acceptance.source_path(self.repo, relative)

    def testNoOverwriteOrSnapshotInsideWorktree(self):
        with self.assertRaises(ValueError):
            acceptance.freeze(self.repo, self.repo / "snapshot")
        self.snapshot.mkdir()
        with self.assertRaises(ValueError):
            acceptance.freeze(self.repo, self.snapshot)

    def testArchiveDeterminism(self):
        self.freeze()
        first, second = self.root / "one.tar.gz", self.root / "two.tar.gz"
        acceptance.archive_snapshot(self.snapshot, first, "source")
        acceptance.archive_snapshot(self.snapshot, second, "source")
        self.assertEqual(first.read_bytes(), second.read_bytes())

    def testTrackedAndNewBuildInputsSelectedWithoutPersonalReports(self):
        outputs = [b"App.swift\0AGENTS.md\0Gone.swift\0Docs/DemoSource/README.md\0", b"Gone.swift\0",
                   b"Docs/private-report.md\0Docs/LIVE_CHANNEL_PREVIEW.md\0Docs/LIVE_CHANNEL_PREVIEW-private.md\0Docs/RELEASE_NOTES_0.7.0.md\0Docs/RELEASE_READINESS_0.7.3.md\0OKVideoMac/macOS/OKVideoMac/New.swift\0Tools/SourceAudit/new.py\0"]
        with patch.object(acceptance.subprocess, "check_output", side_effect=outputs):
            self.assertEqual(acceptance.selected_files(self.repo),
                             ["App.swift", "Docs/LIVE_CHANNEL_PREVIEW.md", "Docs/RELEASE_NOTES_0.7.0.md",
                              "Docs/RELEASE_READINESS_0.7.3.md",
                              "OKVideoMac/macOS/OKVideoMac/New.swift", "Tools/SourceAudit/new.py"])

    def testOrdinaryReleaseStillRejectsDirtyWorktree(self):
        with patch.object(release, "run", return_value=" M App.swift"):
            with self.assertRaisesRegex(SystemExit, "clean worktree"):
                release.validate_repo(self.repo, "HEAD")

    def testAcceptanceCannotBeDistributionOrNotarized(self):
        script = Path(__file__).resolve().parents[2] / "OKVideoMac/macOS/OKVideoMac/Scripts/package-app.sh"
        for args in [("--mode", "distribution"), ("--notarize",)]:
            result = subprocess.run(["bash", str(script), "--local-acceptance", *args], capture_output=True, text=True)
            self.assertEqual(result.returncode, 64)
            self.assertIn("cannot use distribution", result.stderr)


if __name__ == "__main__":
    unittest.main()
