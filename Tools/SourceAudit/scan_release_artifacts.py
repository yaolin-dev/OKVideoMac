#!/usr/bin/env python3
"""Fail a release when common secrets or forbidden local literals are present."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import tarfile
import zipfile
from pathlib import Path
from typing import BinaryIO, Iterable


CHUNK_SIZE = 1024 * 1024
OVERLAP = 512
SECRET_PATTERNS = (
    ("private-key", re.compile(rb"-----BEGIN (?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----")),
    ("aws-access-key", re.compile(rb"\bAKIA[0-9A-Z]{16}\b")),
    ("github-token", re.compile(rb"\bgh[pousr]_[A-Za-z0-9]{30,}\b")),
    ("slack-token", re.compile(rb"\bxox[baprs]-[A-Za-z0-9-]{20,}\b")),
    ("openai-style-key", re.compile(rb"\bsk-[A-Za-z0-9_-]{20,}\b")),
    (
        "credential-assignment",
        re.compile(
            rb"(?i)\b(?:api[_-]?key|password|passwd|access[_-]?token|"
            rb"refresh[_-]?token|client[_-]?secret|apple[_-]?id[_-]?password|"
            rb"ac_password)\s*[:=]\s*(?:[\"'][A-Za-z0-9+/=_-]{8,}[\"']|"
            rb"[A-Za-z0-9+/=_-]{24,})"
        ),
    ),
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("paths", nargs="+", type=Path)
    parser.add_argument(
        "--forbidden-literal",
        action="append",
        default=[],
        help="Exact local path or other byte sequence that must not ship.",
    )
    parser.add_argument("--json-output", type=Path)
    return parser.parse_args()


def iter_paths(roots: Iterable[Path]) -> Iterable[Path]:
    for root in roots:
        if not root.exists():
            raise FileNotFoundError(root)
        if root.is_symlink():
            continue
        if root.is_file():
            if root.name == ".git":
                continue
            yield root
            continue
        for path in sorted(root.rglob("*")):
            if ".git" in path.relative_to(root).parts:
                continue
            if path.is_file() and not path.is_symlink():
                yield path


def scan_stream(
    stream: BinaryIO,
    label: str,
    forbidden: tuple[bytes, ...],
) -> list[dict[str, str]]:
    findings: list[dict[str, str]] = []
    previous = b""
    while True:
        chunk = stream.read(CHUNK_SIZE)
        if not chunk:
            break
        data = previous + chunk
        for literal in forbidden:
            if literal and literal in data:
                findings.append(
                    {
                        "artifact": label,
                        "kind": "forbidden-literal",
                        "fingerprint": hashlib.sha256(literal).hexdigest()[:16],
                    }
                )
        for kind, pattern in SECRET_PATTERNS:
            match = pattern.search(data)
            if match:
                findings.append(
                    {
                        "artifact": label,
                        "kind": kind,
                        "fingerprint": hashlib.sha256(match.group(0)).hexdigest()[:16],
                    }
                )
        previous = data[-OVERLAP:]
    unique: dict[tuple[str, str, str], dict[str, str]] = {}
    for finding in findings:
        key = (
            finding["artifact"],
            finding["kind"],
            finding["fingerprint"],
        )
        unique[key] = finding
    return list(unique.values())


def scan_file(path: Path, forbidden: tuple[bytes, ...]) -> list[dict[str, str]]:
    findings: list[dict[str, str]] = []
    label = path.name
    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as archive:
            for info in archive.infolist():
                if info.is_dir():
                    continue
                with archive.open(info) as stream:
                    findings.extend(
                        scan_stream(stream, f"{label}!/{info.filename}", forbidden)
                    )
        return findings
    if tarfile.is_tarfile(path):
        with tarfile.open(path, "r:*") as archive:
            for member in archive:
                if not member.isfile():
                    continue
                stream = archive.extractfile(member)
                if stream is not None:
                    with stream:
                        findings.extend(
                            scan_stream(stream, f"{label}!/{member.name}", forbidden)
                        )
        return findings
    with path.open("rb") as stream:
        findings.extend(scan_stream(stream, label, forbidden))
    return findings


def main() -> int:
    args = parse_args()
    forbidden = tuple(value.encode("utf-8") for value in args.forbidden_literal)
    findings: list[dict[str, str]] = []
    scanned_files = 0
    for path in iter_paths(args.paths):
        scanned_files += 1
        findings.extend(scan_file(path, forbidden))
    result = {
        "schema": 1,
        "status": "CLEAN" if not findings else "FINDINGS",
        "scanned_files": scanned_files,
        "forbidden_literal_count": len(forbidden),
        "findings": findings,
    }
    if args.json_output:
        args.json_output.parent.mkdir(parents=True, exist_ok=True)
        args.json_output.write_text(
            json.dumps(result, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if not findings else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, tarfile.TarError, zipfile.BadZipFile) as error:
        print(f"Sensitive information scan failed: {error}", file=sys.stderr)
        raise SystemExit(2)
