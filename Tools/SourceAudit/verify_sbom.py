#!/usr/bin/env python3
"""Verify packaged Mach-O and Gradle inventories against generated SBOMs."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
from pathlib import Path
from approved_inventory import require_approved
from crash_sdk_inventory import verify_static_sdk_documents
from generate_sbom import android_bridge_version


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def macho_paths(app: Path) -> set[str]:
    result = set()
    for path in (app / "Contents").rglob("*"):
        if path.is_file() and not path.is_symlink():
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


def verify_android_bridge_documents(spdx: dict, cdx: dict, version: str, apk: Path) -> None:
    expected_purl = f"pkg:generic/OKVideoMac-AndroidDexBridge@{version}"
    digest = sha256(apk)
    packages = [p for p in spdx.get("packages", []) if p.get("name") == "AndroidDexBridge"]
    if len(packages) != 1:
        raise SystemExit("Android Bridge SPDX aggregate is missing or duplicated")
    package = packages[0]
    purls = [r.get("referenceLocator") for r in package.get("externalRefs", [])
             if r.get("referenceType") == "purl"]
    if (package.get("versionInfo") != version or purls != [expected_purl]
            or package.get("checksums") != [{"algorithm": "SHA256", "checksumValue": digest}]):
        raise SystemExit("Android Bridge SPDX version, purl or APK hash mismatch")
    components = [p for p in cdx.get("components", []) if p.get("name") == "AndroidDexBridge"]
    if len(components) != 1:
        raise SystemExit("Android Bridge CycloneDX aggregate is missing or duplicated")
    component = components[0]
    if (cdx.get("metadata", {}).get("component", {}).get("version") != version
            or component.get("version") != version or component.get("purl") != expected_purl
            or component.get("bom-ref") != expected_purl
            or component.get("hashes") != [{"alg": "SHA-256", "content": digest}]):
        raise SystemExit("Android Bridge CycloneDX version, purl or APK hash mismatch")


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
    android_cdx = json.loads((sbom / "OKVideoMac-Android.cdx.json").read_text(encoding="utf-8"))
    verify_android_bridge_documents(android, android_cdx,
        android_bridge_version(Path(args.gradle_lock).resolve()),
        app / "Contents/Resources/AndroidDexBridge-release.apk")
    cdx = json.loads((sbom / "OKVideoMac-macOS.cdx.json").read_text(encoding="utf-8"))
    verify_static_sdk_documents(app, mac, cdx)
    native_packages = [package for package in mac["packages"] if package.get("packageFileName")]
    declared_paths = {package["packageFileName"] for package in native_packages}
    actual_paths = macho_paths(app)
    if actual_paths != declared_paths:
        raise SystemExit(
            f"Mach-O/SBOM mismatch: missing={sorted(actual_paths-declared_paths)}, "
            f"stale={sorted(declared_paths-actual_paths)}"
        )
    require_approved(actual_paths)
    if len(declared_paths) != len(native_packages):
        raise SystemExit("Duplicate Mach-O paths in SBOM")
    for package in native_packages:
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
    print(f"SBOM verification passed: {len(actual_paths)} Mach-O; {len(expected_coordinates)} Maven modules; 2 static crash SDKs")


if __name__ == "__main__":
    main()
