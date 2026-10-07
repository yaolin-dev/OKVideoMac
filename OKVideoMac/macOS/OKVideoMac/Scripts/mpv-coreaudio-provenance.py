#!/usr/bin/env python3
"""Bind the CoreAudio backport, release build input and packaged machine code."""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent
PATCHES = ["mpv-0.41.0-coreaudio-init-cleanup.patch",
           "mpv-0.41.0-coreaudio-late-hotplug.patch",
           "mpv-0.41.0-coreaudio-disposed-unit.patch",
           "mpv-0.41.0-coreaudio-hotplug-init-failure.patch"]
COMMITS = ["af067b5ea8e5fe396ebd9d3f895e51a7e75b3c09",
           "c5d391adba7bd024954d0df1e0405f5749f4d4ca"]
COREAUDIO_SHA256 = "61cef22aaa5f6fd0444930c9702f66719900f190af8cbc0479613df82ebf4f61"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def code_identity(library):
    uuid = subprocess.check_output(["xcrun", "dwarfdump", "--uuid", str(library)], text=True).split()[1]
    rows = subprocess.check_output(["otool", "-s", "__TEXT", "__text", str(library)], text=True).splitlines()[2:]
    return {"uuid": uuid, "text_sha256": hashlib.sha256("\n".join(rows).encode()).hexdigest()}


def main():
    p = argparse.ArgumentParser()
    p.add_argument("mode", choices=["apply", "record", "verify", "verify-bundle"])
    p.add_argument("--source", type=Path)
    p.add_argument("--library", type=Path)
    p.add_argument("--receipt", type=Path)
    a = p.parse_args()
    if a.mode == "apply":
        for name in PATCHES:
            subprocess.run(["patch", "--batch", "--forward", "-p1", "-d", str(a.source),
                            "-i", str(PROJECT / "Patches" / name)], check=True)
        require(sha(a.source / "audio/out/ao_coreaudio.c") == COREAUDIO_SHA256, "Unexpected patched CoreAudio source")
        return
    if a.mode == "record":
        require(sha(a.source / "audio/out/ao_coreaudio.c") == COREAUDIO_SHA256, "Unexpected compiled CoreAudio source")
        receipt = {"schema": 1, "buildtype": "release", "upstream_commits": COMMITS,
                   "source_archive_sha256": "ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209",
                   "coreaudio_source_sha256": sha(a.source / "audio/out/ao_coreaudio.c"),
                   "patches": {name: sha(PROJECT / "Patches" / name) for name in PATCHES},
                   "library_sha256": sha(a.library), **code_identity(a.library)}
        a.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
    else:
        receipt = json.loads(a.receipt.read_text())
        require(receipt["buildtype"] == "release" and receipt["upstream_commits"] == COMMITS, "Unexpected libmpv build/commits")
        require(receipt["coreaudio_source_sha256"] == COREAUDIO_SHA256, "Unexpected CoreAudio source hash")
        for k, v in code_identity(a.library).items():
            require(receipt[k] == v, f"Packaged libmpv {k} differs from rebuilt input")
        if a.mode == "verify":
            require(receipt["library_sha256"] == sha(a.library), "Stale/changed libmpv input")
            require(receipt["patches"] == {n: sha(PROJECT / "Patches" / n) for n in PATCHES}, "Rebuild libmpv after patch changes")
        else:
            require(receipt["patches"] == {n: sha(a.receipt.parent / n) for n in PATCHES}, "Bundled mpv patches differ from compiled inputs")
        print("PASS: libmpv CoreAudio build provenance", receipt["uuid"])


if __name__ == "__main__":
    main()
