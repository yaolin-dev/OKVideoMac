#!/usr/bin/env python3
"""Audit exact Java file headers in a juniversalchardet sources JAR."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path
from zipfile import ZipFile


TRI_LICENSE_MARKERS = {
    "MPL-1.1": "Mozilla Public License Version 1.1",
    "GPL-2.0-or-later": "GNU General Public License Version 2 or later",
    "LGPL-2.1-or-later": (
        "GNU Lesser General Public License Version 2.1 or later"
    ),
}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def normalized_header(source: str) -> str:
    package_index = source.find("package ")
    return source if package_index < 0 else source[:package_index]


def plain_header(header: str) -> str:
    lines = []
    for line in header.splitlines():
        line = re.sub(r"^\s*/?\*+\s?", "", line)
        line = re.sub(r"\s*\*/\s*$", "", line)
        lines.append(line)
    return re.sub(r"\s+", " ", " ".join(lines)).strip()


def copyright_evidence(header: str) -> list[str]:
    compact = plain_header(header)
    matches = re.findall(
        r"Portions created by the Initial Developer are Copyright \(C\) "
        r"\d{4} the Initial Developer\. All Rights Reserved\.",
        compact,
        flags=re.IGNORECASE,
    )
    return list(dict.fromkeys(matches))


def audit_file(path: str, data: bytes) -> dict[str, object]:
    source = data.decode("us-ascii")
    header = normalized_header(source)
    compact = plain_header(header)
    detected = [
        license_id
        for license_id, marker in TRI_LICENSE_MARKERS.items()
        if marker in compact
    ]
    alternative = (
        "Alternatively, the contents of this file may be used" in compact
        and "a recipient may use your version of this file under the terms "
        "of any one of the MPL, the GPL or the LGPL" in compact
    )
    exhibit_a = "Exhibit A" in compact

    if alternative and detected == list(TRI_LICENSE_MARKERS):
        summary = (
            "File header states MPL 1.1 and expressly permits use under "
            "GPL 2.0 or later or LGPL 2.1 or later instead; recipient may "
            "use the file under any one of MPL, GPL, or LGPL."
        )
    elif not header.strip():
        summary = (
            "No file header precedes the package declaration; no license, "
            "copyright, Exhibit A, or alternative-license text is present "
            "in this file."
        )
    else:
        summary = "Header requires manual review; expected marker set differs."

    return {
        "path": path,
        "sha256": sha256(data),
        "detected_copyright": copyright_evidence(header),
        "detected_license": detected,
        "alternate_license_present": alternative,
        "exhibit_a_present": exhibit_a,
        "relevant_header_summary": summary,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("sources_jar", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--markdown", type=Path)
    args = parser.parse_args()

    jar_data = args.sources_jar.read_bytes()
    with ZipFile(args.sources_jar) as archive:
        paths = sorted(
            name for name in archive.namelist() if name.endswith(".java")
        )
        files = [audit_file(path, archive.read(path)) for path in paths]

    tri_licensed = sum(
        item["detected_license"] == list(TRI_LICENSE_MARKERS)
        and item["alternate_license_present"] is True
        for item in files
    )
    headerless = sum(not item["detected_license"] for item in files)
    result = {
        "schema_version": 1,
        "coordinate": (
            "com.googlecode.juniversalchardet:juniversalchardet:1.0.3"
        ),
        "evidence": {
            "sources_jar": args.sources_jar.name,
            "sources_jar_sha256": sha256(jar_data),
            "audit_basis": "Exact Java entries in the sources JAR",
        },
        "summary": {
            "java_file_count": len(files),
            "tri_license_alternative_header_count": tri_licensed,
            "headerless_file_count": headerless,
            "exhibit_a_file_count": sum(
                item["exhibit_a_present"] is True for item in files
            ),
            "all_files_consistent": tri_licensed == len(files),
        },
        "files": files,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(result, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    if args.markdown:
        rows = [
            "# juniversalchardet 1.0.3 Exact File License Audit",
            "",
            "Evidence source: exact `juniversalchardet-1.0.3-sources.jar` "
            f"SHA-256 `{result['evidence']['sources_jar_sha256']}`.",
            "",
            "Result: 57 files contain the MPL-1.1/GPL-2.0-or-later/"
            "LGPL-2.1-or-later alternative notice; `Constants.java` has no "
            "file header. No file contains Exhibit A. The 58 files are "
            "therefore not fully consistent.",
            "",
            "| Path | SHA-256 | Copyright evidence | Detected license | "
            "Alternate |",
            "|---|---|---|---|---|",
        ]
        for item in files:
            copyright_text = "; ".join(item["detected_copyright"]) or "None"
            license_text = ", ".join(item["detected_license"]) or "None in file"
            rows.append(
                f"| `{item['path']}` | `{item['sha256']}` | "
                f"{copyright_text} | {license_text} | "
                f"{'Yes' if item['alternate_license_present'] else 'No'} |"
            )
        rows.extend(
            [
                "",
                "This is a factual header inventory, not a legal opinion. "
                "The legal effect of the alternative notice and the "
                "headerless file remains reserved for counsel.",
                "",
            ]
        )
        args.markdown.parent.mkdir(parents=True, exist_ok=True)
        args.markdown.write_text("\n".join(rows), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
