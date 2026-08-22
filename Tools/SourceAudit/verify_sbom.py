#!/usr/bin/env python3
"""Verify packaged Mach-O and Gradle inventories against generated SBOMs."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
from pathlib import Path


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def macho_paths(app: Path) -> set[str]:
    result = set()
    for path in (app / "Contents").rglob("*"):
        if path.is_file():
            detected = subprocess.run(["file", str(path)], check=True, capture_output=True, text=True)
            if "Mach-O" in detected.stdout:
                result.add(path.relative_to(app).as_posix())
    return result


def locked_coordinates(lock: Path) -> set[str]:
    return {
        line.split("=", 1)[0]
        for line in lock.read_text(encoding="utf-8").splitlines()
        # Gradle records dependency-free configurations as ``empty=<configs>``.
        # This is lock metadata rather than a Maven coordinate.
        if line and not line.startswith("#") and not line.startswith("empty=")
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--gradle-lock", required=True)
    parser.add_argument("--sbom-dir", required=True)
    args = parser.parse_args()
    app = Path(args.app).resolve()
    sbom = Path(args.sbom_dir).resolve()
    mac = json.loads((sbom / "OKVideoMac-macOS.spdx.json").read_text(encoding="utf-8"))
    android = json.loads((sbom / "OKVideoMac-Android.spdx.json").read_text(encoding="utf-8"))
    declared_paths = {package["packageFileName"] for package in mac["packages"]}
    actual_paths = macho_paths(app)
    if actual_paths != declared_paths:
        raise SystemExit(
            f"Mach-O/SBOM mismatch: missing={sorted(actual_paths-declared_paths)}, "
            f"stale={sorted(declared_paths-actual_paths)}"
        )
    if len(actual_paths) != 28:
        raise SystemExit(f"Expected 28 Mach-O objects, found {len(actual_paths)}")
    for package in mac["packages"]:
        relative = package["packageFileName"]
        if relative == "Contents/MacOS/OKVideoMac":
            if package.get("checksums"):
                raise SystemExit("Main executable hash must avoid the outer-signature cycle")
            continue
        expected = package["checksums"][0]["checksumValue"]
        if sha256(app / relative) != expected:
            raise SystemExit(f"Stale SBOM checksum: {relative}")
    declared_coordinates = {
        f"{package['name']}:{package['versionInfo']}"
        for package in android["packages"]
        if ":" in package["name"]
    }
    expected_coordinates = locked_coordinates(Path(args.gradle_lock).resolve())
    if declared_coordinates != expected_coordinates:
        raise SystemExit(
            f"Gradle/SBOM mismatch: missing={sorted(expected_coordinates-declared_coordinates)}, "
            f"stale={sorted(declared_coordinates-expected_coordinates)}"
        )
    if any(package["name"] == "xpp3:xpp3" for package in android["packages"]):
        raise SystemExit("Excluded xpp3 is present in Android SBOM")
    print(f"SBOM verification passed: {len(actual_paths)} Mach-O; {len(expected_coordinates)} Maven modules")


if __name__ == "__main__":
    main()
