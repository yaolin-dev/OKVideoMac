#!/usr/bin/env python3
"""Freeze uncommitted build inputs without changing any Git object or index."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
import re
from pathlib import Path, PurePosixPath
import stat
import subprocess
import tarfile
import gzip

MANIFEST = "LOCAL_ACCEPTANCE_SNAPSHOT.json"
# Untracked reports/user samples are not build inputs. Never sweep arbitrary
# personal files into an artifact; new implementation files use these roots.
UNTRACKED_ROOTS = ("OKVideoMac/macOS/OKVideoMac/", "OKVideoMac/Helpers/", "Tools/SourceAudit/")
UPDATE_INPUTS = {"ThirdParty/sparkle-lock.json", "ThirdParty/approved-macho-paths.json",
                 "OKVideoMac/THIRD_PARTY_LICENSES/Sparkle-LICENSE.txt", "Docs/AUTOMATIC_UPDATES.md"}
RELEASE_DOCUMENT_PATTERN = re.compile(
    r"Docs/RELEASE_(?:NOTES|READINESS)_\d+\.\d+\.\d+\.md\Z"
)


def canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()


def source_path(root: Path, relative: str) -> Path:
    path = PurePosixPath(relative)
    if not relative or path.is_absolute() or any(p in ("..", ".git") for p in path.parts):
        raise ValueError("Unsafe snapshot path")
    result = root / path
    for part in [result, *result.parents]:
        if part == root:
            break
        if part.is_symlink():
            raise ValueError("Snapshot inputs must not contain symlinks")
    if not result.is_file():
        raise ValueError("Snapshot input is not a regular file")
    return result


def record(root: Path, relative: str) -> dict:
    path = source_path(root, relative)
    return {"path": relative, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "executable": bool(path.stat().st_mode & 0o111)}


def selected_files(repo: Path) -> list[str]:
    def files(*arguments: str) -> set[str]:
        raw = subprocess.check_output(["git", "ls-files", "-z", *arguments], cwd=repo)
        return {os.fsdecode(p) for p in raw.split(b"\0") if p}
    tracked = files("--cached") - files("--deleted")
    new = {
        p for p in files("--others", "--exclude-standard")
        if p.startswith(UNTRACKED_ROOTS) or p in UPDATE_INPUTS or RELEASE_DOCUMENT_PATTERN.fullmatch(p)
    }
    return sorted(p for p in (tracked | new) - {"AGENTS.md", MANIFEST}
                  if not p.startswith("Docs/DemoSource/"))


def worktree_context(repo: Path, names: list[str]) -> dict:
    def git(*args: str) -> str:
        return subprocess.check_output(["git", *args], cwd=repo, text=True).strip()
    branch = git("branch", "--show-current")
    if not branch or branch == "main":
        raise ValueError("Local acceptance requires a named development branch, not main")
    modified = set(git("diff", "HEAD", "--name-only", "-z").split("\0"))
    untracked = set(git("ls-files", "--others", "--exclude-standard", "-z").split("\0"))
    project = (repo / "OKVideoMac/macOS/OKVideoMac/project.yml").read_text()
    def setting(key: str) -> str:
        match = re.search(r"^\s*" + key + r":\s*([\w.]+)\s*$", project, re.MULTILINE)
        if not match:
            raise ValueError("Missing version/build in captured project")
        return match.group(1)
    return {"branch": branch, "baselineHEAD": git("rev-parse", "HEAD"),
            "version": setting("MARKETING_VERSION"), "build": setting("CURRENT_PROJECT_VERSION"),
            "trackedModifications": sorted(set(names) & modified),
            "includedUntrackedSource": sorted(set(names) & untracked)}


def freeze(repo: Path, destination: Path) -> dict:
    repo = repo.resolve()
    destination = destination.resolve()
    if destination.exists() or destination == repo or repo in destination.parents:
        raise ValueError("Snapshot destination must be new and outside the worktree")
    names = selected_files(repo)
    before = [record(repo, name) for name in names]
    context = worktree_context(repo, names)
    destination.mkdir(parents=True, mode=0o700)
    for entry in before:
        source = source_path(repo, entry["path"])
        target = destination / entry["path"]
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(source.read_bytes())
        target.chmod(0o755 if entry["executable"] else 0o644)
    if (names != selected_files(repo) or before != [record(repo, name) for name in names]
            or context != worktree_context(repo, names)):
        raise ValueError("Worktree changed during snapshot capture; retry with stable inputs")
    metadata = {"schema_version": 1, "kind": "local-uncommitted-acceptance", "git_commit": None,
                "base_git_commit": context["baselineHEAD"], **context,
                "gitCommitBound": False, "acceptanceOnly": True, "publicReleaseEligible": False,
                "created_at": datetime.now(timezone.utc).isoformat(),
                "files": before, "source_sha256": hashlib.sha256(canonical(before)).hexdigest()}
    (destination / MANIFEST).write_bytes(canonical(metadata) + b"\n")
    validate(destination)
    # Host paths are private audit evidence, not redistributable build inputs.
    # Keep them outside the snapshot/archive and the App's sensitive-scan boundary.
    provenance = {**metadata, "repositoryRoot": str(repo), "worktreePath": str(repo),
                  "snapshotPath": str(destination),
                  "snapshotManifestSHA256": hashlib.sha256((destination / MANIFEST).read_bytes()).hexdigest()}
    private_path = destination.parent / (destination.name + "-PRIVATE-PROVENANCE.json")
    with private_path.open("x") as file:
        json.dump(provenance, file, ensure_ascii=False, indent=2)
    private_path.chmod(0o600)
    return metadata


def validate(repo: Path) -> dict:
    metadata = json.loads(source_path(repo, MANIFEST).read_bytes())
    if metadata.get("kind") != "local-uncommitted-acceptance" or metadata.get("git_commit") is not None:
        raise ValueError("Not an uncommitted local acceptance snapshot")
    if (metadata.get("gitCommitBound") is not False or metadata.get("acceptanceOnly") is not True
            or metadata.get("publicReleaseEligible") is not False
            or not metadata.get("branch") or metadata["branch"] == "main"
            or metadata.get("baselineHEAD") != metadata.get("base_git_commit")):
        raise ValueError("Invalid local acceptance Git provenance")
    files = metadata["files"]
    paths = [entry["path"] for entry in files]
    if not paths or paths != sorted(set(paths)) or MANIFEST in paths:
        raise ValueError("Invalid snapshot file inventory")
    if hashlib.sha256(canonical(files)).hexdigest() != metadata["source_sha256"]:
        raise ValueError("Snapshot inventory digest mismatch")
    if [record(repo, name) for name in paths] != files:
        raise ValueError("Snapshot source changed since capture")
    captured = set(paths) | {MANIFEST}
    for path in repo.rglob("*"):
        relative = path.relative_to(repo)
        # Build products/configuration produced by the existing toolchains are
        # not source inputs and never enter the corresponding-source archive.
        if any(part in ("build", ".build", ".gradle", ".swiftpm", "xcuserdata") for part in relative.parts):
            continue
        if relative.as_posix() == "OKVideoMac/Helpers/AndroidDexBridge/local.properties":
            continue
        if path.is_file() and relative.as_posix() not in captured:
            raise ValueError("Uncaptured file added to snapshot source tree")
    return metadata


def archive_snapshot(repo: Path, output: Path, prefix: str) -> None:
    metadata = validate(repo)
    # Only captured input bytes, never Gradle/Xcode products generated afterward.
    with output.open("wb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w") as archive:
            for name in sorted([entry["path"] for entry in metadata["files"]] + [MANIFEST]):
                path = source_path(repo, name)
                info = tarfile.TarInfo(prefix + "/" + name)
                info.size = path.stat().st_size
                info.mode = 0o755 if path.stat().st_mode & stat.S_IXUSR else 0o644
                info.mtime = 0
                with path.open("rb") as source:
                    archive.addfile(info, source)
    validate(repo)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--destination", type=Path)
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    if args.verify:
        value = validate(args.repo)
    elif args.destination:
        value = freeze(args.repo, args.destination)
    else:
        parser.error("--destination or --verify is required")
    print("Local acceptance source SHA-256: " + value["source_sha256"])


if __name__ == "__main__":
    main()
