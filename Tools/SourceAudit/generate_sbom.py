#!/usr/bin/env python3
"""Generate deterministic SPDX and CycloneDX SBOMs for the packaged app/APK."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import subprocess
import uuid
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote


REPO = Path(__file__).resolve().parents[2]
SPDX_NS = uuid.UUID("2a2eb62c-ad1f-4e9b-99b9-6d3ee855ecf7")
CDX_NS = uuid.UUID("ce6fdc54-4547-4142-b70f-3ed50cbd18f8")

NATIVE = {
    "OKVideoMac": ("OKVideoMac", "GPL-3.0-only"),
    "node": ("22.23.0", "MIT"),
    "libOKMPVBridge.dylib": ("0.3.41", "GPL-3.0-only"),
    "libOKQuickJS.dylib": ("2025-04-26", "GPL-3.0-only AND MIT"),
    "libmpv.dylib": ("0.41.0", "GPL-2.0-or-later"),
    "libavcodec.61.dylib": ("7.1.4", "LGPL-2.1-or-later"),
    "libavfilter.10.dylib": ("7.1.4", "LGPL-2.1-or-later"),
    "libavformat.61.dylib": ("7.1.4", "LGPL-2.1-or-later"),
    "libavutil.59.dylib": ("7.1.4", "LGPL-2.1-or-later"),
    "libswresample.5.dylib": ("7.1.4", "LGPL-2.1-or-later"),
    "libswscale.8.dylib": ("7.1.4", "LGPL-2.1-or-later"),
    "libass.9.dylib": ("0.17.5", "ISC"),
    "libplacebo.360.dylib": ("7.360.1", "LGPL-2.1-or-later"),
    "libfreetype.6.dylib": ("2.14.3", "FTL"),
    "libharfbuzz.0.dylib": ("14.2.1", "MIT"),
    "libfribidi.0.dylib": ("1.0.16", "LGPL-2.1-or-later"),
    "libbrotlidec.1.dylib": ("1.2.0", "MIT"),
    "libbrotlicommon.1.dylib": ("1.2.0", "MIT"),
    "liblcms2.2.dylib": ("2.19.1", "MIT"),
    "libpng16.16.dylib": ("1.6.58", "Libpng"),
    "libjpeg.8.dylib": ("3.2.0", "BSD-3-Clause AND Zlib AND LicenseRef-IJG"),
    "liblzma.5.dylib": ("5.8.3", "0BSD"),
    "libsqlite3.dylib": ("3.53.4", "LicenseRef-Public-Domain"),
    "libiconv.2.dylib": ("1.18", "LGPL-2.1-or-later"),
    "libbz2.1.0.dylib": ("1.0.8", "bzip2-1.0.6"),
    "libz.1.dylib": ("1.3.2", "Zlib"),
    "libc++.1.0.dylib": ("11.1.0", "Apache-2.0 WITH LLVM-exception"),
    "libc++abi.1.dylib": ("11.1.0", "Apache-2.0 WITH LLVM-exception"),
}

LICENSE_REFS = {
    "LicenseRef-IJG": (
        "Independent JPEG Group notice",
        REPO / "OKVideoMac/THIRD_PARTY_LICENSES/libjpeg-turbo-README.ijg",
    ),
    "LicenseRef-Public-Domain": (
        "SQLite public-domain dedication",
        REPO / "OKVideoMac/THIRD_PARTY_LICENSES/SQLite-Public-Domain.txt",
    ),
    "LicenseRef-Bouncy-Castle": (
        "Bouncy Castle license",
        REPO / "OKVideoMac/THIRD_PARTY_LICENSES/Bouncy-Castle-MIT.txt",
    ),
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def safe_id(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9.-]", "-", value)


def timestamp(repo: Path) -> str:
    value = subprocess.check_output(
        ["git", "show", "-s", "--format=%cI", "HEAD"], cwd=repo, text=True
    ).strip()
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return parsed.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def is_macho(path: Path) -> bool:
    result = subprocess.run(["file", str(path)], check=True, capture_output=True, text=True)
    return "Mach-O" in result.stdout


def native_inventory(app: Path) -> list[dict[str, str]]:
    result: list[dict[str, str]] = []
    for path in sorted((app / "Contents").rglob("*")):
        if not path.is_file() or not is_macho(path):
            continue
        relative = path.relative_to(app).as_posix()
        basename = path.name
        if basename not in NATIVE:
            raise SystemExit(f"No SBOM metadata for bundled Mach-O: {relative}")
        version, license_id = NATIVE[basename]
        result.append(
            {
                "name": basename,
                "version": version,
                "license": license_id,
                "path": relative,
                "sha256": "" if relative == "Contents/MacOS/OKVideoMac" else sha256(path),
            }
        )
    if len(result) != 28:
        raise SystemExit(f"Expected 28 bundled Mach-O objects, found {len(result)}")
    return result


def maven_license(group: str, artifact: str) -> str:
    coordinate = f"{group}:{artifact}"
    if coordinate == "com.googlecode.juniversalchardet:juniversalchardet":
        return "MPL-1.1"
    if group == "net.engio" or coordinate == "org.slf4j:slf4j-api" or group == "org.brotli":
        return "MIT"
    if group == "org.bouncycastle":
        return "LicenseRef-Bouncy-Castle"
    return "Apache-2.0"


def artifact_file(cache: Path, group: str, artifact: str, version: str) -> Path | None:
    root = cache / group / artifact / version
    if not root.is_dir():
        return None
    files = [candidate for candidate in root.rglob("*") if candidate.is_file()]
    exact = []
    for suffix in (".aar", ".jar", ".pom", ".module"):
        exact.extend(path for path in files if path.name == f"{artifact}-{version}{suffix}")
    return sorted(exact)[0] if exact else None


def android_inventory(lock: Path, cache: Path, apk: Path) -> list[dict[str, str]]:
    result = [
        {
            "name": "AndroidDexBridge",
            "version": "0.3.14",
            "license": "GPL-3.0-only",
            "purl": "pkg:generic/OKVideoMac-AndroidDexBridge@0.3.14",
            "artifact": "AndroidDexBridge-release.apk",
            "sha256": sha256(apk),
        },
        {
            "name": "FongMi-TV-catvod",
            "version": "5fdff00a602dc56e8ba756174daef20edab024f2",
            "license": "GPL-3.0-only",
            "purl": "pkg:github/FongMi/TV@5fdff00a602dc56e8ba756174daef20edab024f2",
            "artifact": "source compiled into classes.dex",
            "sha256": "",
        },
    ]
    for raw in lock.read_text(encoding="utf-8").splitlines():
        # Gradle records every dependency-free configuration on the single
        # metadata line `empty=<configuration,...>`.  The configuration list
        # changes as Android Gradle Plugin tasks are exercised, but it never
        # represents a Maven component and therefore must not enter the SBOM.
        if not raw or raw.startswith("#") or raw.startswith("empty="):
            continue
        coordinate = raw.split("=", 1)[0]
        pieces = coordinate.split(":")
        if len(pieces) != 3:
            raise SystemExit(f"Unexpected Gradle lock entry: {raw}")
        group, artifact, version = pieces
        source = artifact_file(cache, group, artifact, version)
        result.append(
            {
                "name": f"{group}:{artifact}",
                "version": version,
                "license": maven_license(group, artifact),
                "purl": f"pkg:maven/{quote(group, safe='')}/{quote(artifact, safe='')}@{quote(version, safe='')}",
                "artifact": source.name if source else "",
                "sha256": sha256(source) if source else "",
            }
        )
    return result


def spdx(name: str, version: str, items: list[dict[str, str]], created: str, seed: str) -> dict:
    document_id = str(uuid.uuid5(SPDX_NS, seed))
    packages = []
    relationships = []
    for index, item in enumerate(items, 1):
        package_id = f"SPDXRef-Package-{index}-{safe_id(item['name'])}"
        package = {
            "SPDXID": package_id,
            "name": item["name"],
            "versionInfo": item["version"],
            "downloadLocation": "NOASSERTION",
            "filesAnalyzed": False,
            "licenseConcluded": item["license"],
            "licenseDeclared": item["license"],
            "copyrightText": "NOASSERTION",
        }
        if item.get("path"):
            package["packageFileName"] = item["path"]
        if item.get("sha256"):
            package["checksums"] = [{"algorithm": "SHA256", "checksumValue": item["sha256"]}]
        if item.get("purl"):
            package["externalRefs"] = [{
                "referenceCategory": "PACKAGE-MANAGER",
                "referenceType": "purl",
                "referenceLocator": item["purl"],
            }]
        if item.get("artifact"):
            package["comment"] = f"Resolved artifact: {item['artifact']}"
        packages.append(package)
        relationships.append({
            "spdxElementId": "SPDXRef-DOCUMENT",
            "relationshipType": "DESCRIBES",
            "relatedSpdxElement": package_id,
        })
    document = {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": name,
        "documentNamespace": f"https://okvideomac.invalid/spdx/{document_id}",
        "creationInfo": {"created": created, "creators": ["Tool: OKVideoMac-generate-sbom"]},
        "documentDescribes": [package["SPDXID"] for package in packages],
        "packages": packages,
        "relationships": relationships,
    }
    used_refs = sorted(
        reference
        for reference in LICENSE_REFS
        if any(reference in item["license"] for item in items)
    )
    if used_refs:
        document["hasExtractedLicensingInfos"] = [
            {
                "licenseId": reference,
                "name": LICENSE_REFS[reference][0],
                "extractedText": LICENSE_REFS[reference][1].read_text(encoding="utf-8"),
            }
            for reference in used_refs
        ]
    return document


def cyclonedx(name: str, version: str, items: list[dict[str, str]], created: str, seed: str) -> dict:
    components = []
    for index, item in enumerate(items, 1):
        license_value = item["license"]
        if " AND " in license_value or " OR " in license_value:
            licenses = [{"expression": license_value}]
        elif license_value.startswith("LicenseRef-"):
            licenses = [{"license": {"name": license_value}}]
        else:
            licenses = [{"license": {"id": license_value}}]
        component = {
            "type": "library" if index > 1 else "application",
            "bom-ref": item.get("purl") or f"urn:okvideomac:{safe_id(item['name'])}:{index}",
            "name": item["name"],
            "version": item["version"],
            "licenses": licenses,
            "properties": [],
        }
        if item.get("purl"):
            component["purl"] = item["purl"]
        if item.get("path"):
            component["properties"].append({"name": "okvideomac:bundle-path", "value": item["path"]})
        if item.get("artifact"):
            component["properties"].append({"name": "okvideomac:artifact", "value": item["artifact"]})
        if item.get("sha256"):
            component["hashes"] = [{"alg": "SHA-256", "content": item["sha256"]}]
        components.append(component)
    serial = uuid.uuid5(CDX_NS, seed)
    return {
        "bomFormat": "CycloneDX",
        "specVersion": "1.6",
        "serialNumber": f"urn:uuid:{serial}",
        "version": 1,
        "metadata": {
            "timestamp": created,
            "tools": {"components": [{"type": "application", "name": "OKVideoMac-generate-sbom", "version": "1"}]},
            "component": {"type": "application", "name": name, "version": version},
        },
        "components": components,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--gradle-lock", required=True)
    parser.add_argument("--gradle-cache", default=str(Path.home() / ".gradle/caches/modules-2/files-2.1"))
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()
    app = Path(args.app).resolve()
    output = Path(args.output_dir).resolve()
    output.mkdir(parents=True, exist_ok=True)
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    version = str(info["CFBundleShortVersionString"])
    build = str(info["CFBundleVersion"])
    created = timestamp(REPO)
    native = native_inventory(app)
    android = android_inventory(
        Path(args.gradle_lock).resolve(),
        Path(args.gradle_cache).expanduser().resolve(),
        app / "Contents/Resources/AndroidDexBridge-release.apk",
    )
    seed = f"OKVideoMac-{version}-{build}-" + hashlib.sha256(
        json.dumps([native, android], sort_keys=True).encode()
    ).hexdigest()
    documents = {
        "OKVideoMac-macOS.spdx.json": spdx("OKVideoMac macOS", version, native, created, seed + "-mac-spdx"),
        "OKVideoMac-macOS.cdx.json": cyclonedx("OKVideoMac macOS", version, native, created, seed + "-mac-cdx"),
        "OKVideoMac-Android.spdx.json": spdx("OKVideoMac AndroidDexBridge", "0.3.14", android, created, seed + "-android-spdx"),
        "OKVideoMac-Android.cdx.json": cyclonedx("OKVideoMac AndroidDexBridge", "0.3.14", android, created, seed + "-android-cdx"),
    }
    for filename, document in documents.items():
        write_json(output / filename, document)
    print(f"Generated macOS SBOM: {len(native)} components")
    print(f"Generated Android SBOM: {len(android)} components ({len(android) - 2} locked Maven modules)")


if __name__ == "__main__":
    main()
