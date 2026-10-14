import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import local_acceptance as acceptance

script = Path(__file__).resolve().parents[2] / "OKVideoMac/macOS/OKVideoMac/Scripts/crash-symbols.py"
spec = importlib.util.spec_from_file_location("crash_symbol_source", script)
symbols = importlib.util.module_from_spec(spec)
spec.loader.exec_module(symbols)


class CrashSymbolSourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        (self.repo / "App.swift").write_text("let value = 1\n")
        self.snapshot = self.root / "snapshot"
        with patch.object(acceptance, "selected_files", return_value=["App.swift"]), \
             patch.object(acceptance, "worktree_context", return_value={
                 "branch": "codex/test", "baselineHEAD": "a" * 40,
                 "version": "0.8.6", "build": "139", "trackedModifications": ["App.swift"],
                 "includedUntrackedSource": []}):
            self.manifest = acceptance.freeze(self.repo, self.snapshot)

    def testFrozenSourceBindsBytesWithoutClaimingBaselineCommit(self):
        with patch.object(symbols.subprocess, "check_output", side_effect=AssertionError("No Git in frozen source")):
            result = symbols.source_state(self.snapshot)
        self.assertIsNone(result["commit"])
        self.assertEqual(result["baseline_commit"], "a" * 40)
        self.assertEqual(result["working_files_sha256"], self.manifest["source_sha256"])
        self.assertTrue(result["acceptanceOnly"])
        self.assertFalse(result["publicReleaseEligible"])
        self.assertFalse(result["gitCommitBound"])

    def testTamperedFrozenSourceRejectsSymbolProvenance(self):
        (self.snapshot / "App.swift").write_text("tampered")
        with self.assertRaisesRegex(ValueError, "Source|source"):
            symbols.source_state(self.snapshot)

    def testGitSourceStillRecordsRealCommitAndDirtyState(self):
        with patch.object(symbols.subprocess, "check_output", return_value=b"App.swift\0"), \
             patch.object(symbols, "output", side_effect=["b" * 40, " M App.swift"]):
            result = symbols.source_state(self.repo)
        self.assertEqual(result["commit"], "b" * 40)
        self.assertTrue(result["dirty"])
        self.assertEqual(len(result["working_files_sha256"]), 64)
        self.assertNotIn("acceptanceOnly", result)


if __name__ == "__main__":
    unittest.main()
