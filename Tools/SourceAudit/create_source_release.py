#!/usr/bin/env python3
"""Create deterministic OKVideoMac corresponding-source release artifacts."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
import zipfile
from typing import Optional


def fail(message: str) -> "NoReturn":
    raise SystemExit(message)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def run(repo: Path, *args: str) -> str:
    return subprocess.check_output(args, cwd=repo, text=True).strip()


def atomic_json(path: Path, value: object) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    os.replace(temporary, path)


def verify_binary_binding(binary: Path, index: Path, apk: Optional[Path]) -> None:
    if not zipfile.is_zipfile(binary):
        fail(f"Binary release is not a readable ZIP: {binary}")
    index_suffix = "/Contents/Resources/Legal/Compliance/SOURCE_RELEASE_INDEX.json"
    apk_suffix = "/Contents/Resources/AndroidDexBridge-release.apk"
    with zipfile.ZipFile(binary) as archive:
        index_members = [name for name in archive.namelist() if name.endswith(index_suffix)]
        if len(index_members) != 1:
            fail("Binary ZIP must contain exactly one embedded source release index")
        if archive.read(index_members[0]) != index.read_bytes():
            fail("Binary ZIP source index does not match the generated source release index")
        if apk is not None:
            apk_members = [name for name in archive.namelist() if name.endswith(apk_suffix)]
            if len(apk_members) != 1:
                fail("Binary ZIP must contain exactly one AndroidDexBridge Release APK")
            if hashlib.sha256(archive.read(apk_members[0])).hexdigest() != sha256(apk):
                fail("Binary ZIP APK does not match the APK bound in the source manifest")


def parse_release(repo: Path) -> tuple[str, str]:
    project = repo / "OKVideoMac/macOS/OKVideoMac/project.yml"
    version = None
    build = None
    for line in project.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped.startswith("MARKETING_VERSION:"):
            version = stripped.split(":", 1)[1].strip()
        elif stripped.startswith("CURRENT_PROJECT_VERSION:"):
            build = stripped.split(":", 1)[1].strip()
    if not version or not build:
        fail(f"Cannot read release version/build from {project}")
    return version, build


def validate_repo(repo: Path, commit: str) -> tuple[str, str]:
    if run(repo, "git", "status", "--porcelain", "--untracked-files=all"):
        fail("Source releases require a clean worktree.")
    resolved = run(repo, "git", "rev-parse", "--verify", f"{commit}^{{commit}}")
    timestamp = run(repo, "git", "show", "-s", "--format=%cI", resolved)
    return resolved, timestamp


def download_locked(entry: dict[str, object], cache: Path, offline: bool) -> Path:
    filename = str(entry["filename"])
    expected = str(entry["sha256"])
    destination = cache / filename
    if destination.exists() and sha256(destination) != expected:
        fail(f"Cached source checksum mismatch: {destination}")
    if not destination.exists():
        if offline:
            fail(f"Locked source is missing in offline mode: {destination}")
        request = urllib.request.Request(
            str(entry["url"]), headers={"User-Agent": "OKVideoMac-source-release/1"}
        )
        temporary = destination.with_suffix(destination.suffix + ".download")
        try:
            with urllib.request.urlopen(request) as response, temporary.open("wb") as out:
                shutil.copyfileobj(response, out)
        except Exception:
            temporary.unlink(missing_ok=True)
            raise
        if sha256(temporary) != expected:
            actual = sha256(temporary)
            temporary.unlink(missing_ok=True)
            fail(f"Downloaded source checksum mismatch for {filename}: {actual}")
        os.replace(temporary, destination)
    return destination


def normalized_info(name: str, is_dir: bool, executable: bool = False) -> tarfile.TarInfo:
    info = tarfile.TarInfo(name.rstrip("/") + ("/" if is_dir else ""))
    info.type = tarfile.DIRTYPE if is_dir else tarfile.REGTYPE
    info.mode = 0o755 if is_dir or executable else 0o644
    info.mtime = 0
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "root"
    return info


def deterministic_tar_from_tree(source: Path, output: Path, prefix: str) -> None:
    temporary = output.with_suffix(output.suffix + ".tmp")
    with temporary.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w") as archive:
                root_info = normalized_info(prefix, True)
                archive.addfile(root_info)
                for path in sorted(source.rglob("*"), key=lambda item: item.as_posix()):
                    relative = path.relative_to(source).as_posix()
                    archive_name = f"{prefix.rstrip('/')}/{relative}"
                    if path.is_symlink():
                        fail(f"Symlinks are not allowed in release staging: {path}")
                    if path.is_dir():
                        archive.addfile(normalized_info(archive_name, True))
                    elif path.is_file():
                        executable = bool(path.stat().st_mode & 0o111)
                        info = normalized_info(archive_name, False, executable)
                        info.size = path.stat().st_size
                        with path.open("rb") as data:
                            archive.addfile(info, data)
                    else:
                        fail(f"Unsupported staged entry: {path}")
    os.replace(temporary, output)


def deterministic_git_archive(repo: Path, commit: str, output: Path, prefix: str) -> None:
    temporary = output.with_suffix(output.suffix + ".tmp")
    process = subprocess.Popen(
        ["git", "archive", "--format=tar", f"--prefix={prefix.rstrip('/')}/", commit],
        cwd=repo,
        stdout=subprocess.PIPE,
    )
    assert process.stdout is not None
    with temporary.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
            shutil.copyfileobj(process.stdout, compressed)
    result = process.wait()
    if result != 0:
        temporary.unlink(missing_ok=True)
        fail("git archive failed")
    os.replace(temporary, output)


def safe_relative(name: str) -> PurePosixPath:
    value = PurePosixPath(name)
    if value.is_absolute() or ".." in value.parts:
        fail(f"Unsafe upstream archive path: {name}")
    return value


def filtered_fongmi_archive(source: Path, output: Path, commit: str) -> None:
    selected = ("LICENSE.md", "catvod/build.gradle", "catvod/src/main")
    destination_prefix = f"FongMi-TV-catvod-{commit}"
    temporary = output.with_suffix(output.suffix + ".tmp")
    with tarfile.open(source, "r:gz") as upstream:
        members = upstream.getmembers()
        roots = {safe_relative(member.name).parts[0] for member in members if member.name}
        if len(roots) != 1:
            fail("Unexpected FongMi upstream archive layout")
        root = next(iter(roots))
        filtered: list[tuple[tarfile.TarInfo, PurePosixPath]] = []
        for member in members:
            path = safe_relative(member.name)
            if not path.parts or path.parts[0] != root or len(path.parts) == 1:
                continue
            relative = PurePosixPath(*path.parts[1:])
            relative_text = relative.as_posix()
            if any(
                relative_text == wanted or relative_text.startswith(wanted.rstrip("/") + "/")
                for wanted in selected
            ):
                if not (member.isdir() or member.isfile()):
                    fail(f"Unsupported FongMi subset entry: {member.name}")
                filtered.append((member, relative))
        if not filtered:
            fail("FongMi source subset is empty")
        with temporary.open("wb") as raw:
            with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w") as result:
                    result.addfile(normalized_info(destination_prefix, True))
                    for member, relative in sorted(filtered, key=lambda pair: pair[1].as_posix()):
                        name = f"{destination_prefix}/{relative.as_posix()}"
                        if member.isdir():
                            result.addfile(normalized_info(name, True))
                        else:
                            data = upstream.extractfile(member)
                            if data is None:
                                fail(f"Cannot read upstream source entry: {member.name}")
                            info = normalized_info(name, False, bool(member.mode & 0o111))
                            info.size = member.size
                            result.addfile(info, data)
    os.replace(temporary, output)


def copy_relative(repo: Path, staging: Path, relative: str) -> None:
    source = repo / relative
    destination = staging / relative
    if not source.exists():
        fail(f"Required release material is missing: {source}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    if source.is_dir():
        shutil.copytree(source, destination)
    else:
        shutil.copy2(source, destination)


def write_readme(path: Path, commit: str) -> None:
    path.write_text(
        "OKVideoMac third-party corresponding source\n"
        f"Project commit: {commit}\n\n"
        "SourceInputs contains fixed, SHA-256-verified upstream source archives.\n"
        "BuildRecipes contains the project patch, build scripts, Android dependency\n"
        "lock, change notices, and exact MPL covered-file list. See\n"
        "Docs/SOURCE_RELEASE_PROCESS.md in the project source archive.\n",
        encoding="utf-8",
    )


def make_source_release(args: argparse.Namespace) -> None:
    script = Path(__file__).resolve()
    repo = script.parents[2]
    version, build = parse_release(repo)
    commit, timestamp = validate_repo(repo, args.commit)
    output = Path(args.output_dir).expanduser().resolve()
    cache = Path(args.cache_dir).expanduser().resolve()
    output.mkdir(parents=True, exist_ok=True)
    cache.mkdir(parents=True, exist_ok=True)
    base = f"OKVideoMac-{version}-build{build}"

    lock_path = repo / "ThirdParty/source-release-lock.json"
    lock = json.loads(lock_path.read_text(encoding="utf-8"))
    inputs: list[dict[str, object]] = lock["inputs"]
    resolved_inputs: list[tuple[dict[str, object], Path]] = []
    for entry in inputs:
        resolved_inputs.append((entry, download_locked(entry, cache, args.offline)))

    project_archive = output / f"{base}-source.tar.gz"
    third_party_archive = output / f"{base}-third-party-source.tar.gz"
    licenses_archive = output / f"{base}-licenses.tar.gz"
    deterministic_git_archive(repo, commit, project_archive, f"{base}-source")

    filtered_fongmi = None
    with tempfile.TemporaryDirectory(prefix="okvideomac-source-release-") as temporary:
        root = Path(temporary)
        third = root / "third-party"
        sources = third / "SourceInputs"
        recipes = third / "BuildRecipes"
        sources.mkdir(parents=True)
        recipes.mkdir(parents=True)
        for entry, local in resolved_inputs:
            if bool(entry.get("include_in_bundle", True)):
                shutil.copy2(local, sources / str(entry["filename"]))
            if entry["id"] == "fongmi-tv-upstream":
                commit_id = str(entry["version"])
                filtered_name = f"FongMi-TV-catvod-{commit_id}.tar.gz"
                filtered_fongmi = sources / filtered_name
                filtered_fongmi_archive(local, filtered_fongmi, commit_id)
        for relative in (
            "ThirdParty/source-release-lock.json",
            "ThirdParty/juniversalchardet-1.0.3-covered-files.txt",
            "Docs/MPL_GPL_COMBINATION_REVIEW.md",
            "OKVideoMac/Helpers/AndroidDexBridge/FONGMI_CATVOD_CHANGES.md",
            "OKVideoMac/Helpers/AndroidDexBridge/THIRD_PARTY_NOTICES.md",
            "OKVideoMac/Helpers/AndroidDexBridge/app/gradle.lockfile",
            "OKVideoMac/Helpers/AndroidDexBridge/gradle/wrapper/gradle-wrapper.properties",
            "OKVideoMac/macOS/OKVideoMac/Patches/mpv-0.41.0-coreaudio-without-cocoa.patch",
            "OKVideoMac/macOS/OKVideoMac/Patches/mpv-0.41.0-coreaudio-without-cocoa.NOTICE.md",
            "OKVideoMac/macOS/OKVideoMac/Scripts/build-libmpv.sh",
            "OKVideoMac/macOS/OKVideoMac/Scripts/build-quickjs.sh",
            "OKVideoMac/macOS/OKVideoMac/Scripts/build-android-dex-bridge.sh",
        ):
            copy_relative(repo, recipes, relative)
        write_readme(third / "README.txt", commit)
        deterministic_tar_from_tree(third, third_party_archive, f"{base}-third-party-source")

        licenses = root / "licenses"
        licenses.mkdir()
        for relative in (
            "OKVideoMac/LICENSE",
            "OKVideoMac/NOTICE.md",
            "OKVideoMac/THIRD_PARTY_NOTICES.md",
            "OKVideoMac/THIRD_PARTY_LICENSES",
            "OKVideoMac/Helpers/AndroidDexBridge/THIRD_PARTY_NOTICES.md",
            "OKVideoMac/Helpers/AndroidDexBridge/FONGMI_CATVOD_CHANGES.md",
            "Docs/APP_ICON_PROVENANCE.md",
            "Docs/BINARY_SOURCE_MAPPING.md",
            "Docs/MPL_GPL_COMBINATION_REVIEW.md",
            "Docs/SOURCE_PROVENANCE_MANIFEST.md",
            "Docs/SOURCE_RELEASE_PROCESS.md",
            "Docs/XPP3_1_1_3_3_REMEDIATION.md",
        ):
            copy_relative(repo, licenses, relative)
        deterministic_tar_from_tree(licenses, licenses_archive, f"{base}-licenses")

    artifacts = {
        "project_source": {
            "filename": project_archive.name,
            "sha256": sha256(project_archive),
        },
        "third_party_source": {
            "filename": third_party_archive.name,
            "sha256": sha256(third_party_archive),
        },
        "licenses": {
            "filename": licenses_archive.name,
            "sha256": sha256(licenses_archive),
        },
    }
    locked_inputs = []
    for entry, local in resolved_inputs:
        record = dict(entry)
        record["verified_sha256"] = sha256(local)
        locked_inputs.append(record)
    fongmi_subset_name = (
        f"FongMi-TV-catvod-5fdff00a602dc56e8ba756174daef20edab024f2.tar.gz"
    )
    with tarfile.open(third_party_archive, "r:gz") as archive:
        subset_member = next(
            (member for member in archive.getmembers() if member.name.endswith(fongmi_subset_name)),
            None,
        )
        if subset_member is None:
            fail("Filtered FongMi source archive is absent from third-party bundle")
        extracted = archive.extractfile(subset_member)
        if extracted is None:
            fail("Cannot read filtered FongMi source archive from bundle")
        subset_sha = hashlib.sha256(extracted.read()).hexdigest()

    index = {
        "schema_version": 1,
        "release": {"version": version, "build": build, "git_commit": commit},
        "commit_timestamp": timestamp,
        "publication_status": "generated-and-hash-verified; public upload is a separate release action",
        "build_environment": {
            "architecture": "arm64",
            "macos_deployment_target": "12.0",
            "xcode": "14.2",
            "gradle": "8.9",
            "android_gradle_plugin": "8.7.3",
            "java": "17",
            "mpv_build_system": "Meson (exact options in build-libmpv.sh)",
        },
        "artifacts": artifacts,
        "mappings": {
            "project": {"source": project_archive.name, "git_commit": commit},
            "mpv": {
                "source": "mpv-v0.41.0.tar.gz",
                "source_sha256": "ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209",
                "patch": "mpv-0.41.0-coreaudio-without-cocoa.patch",
                "patch_sha256": sha256(repo / "OKVideoMac/macOS/OKVideoMac/Patches/mpv-0.41.0-coreaudio-without-cocoa.patch"),
                "build_recipe": "OKVideoMac/macOS/OKVideoMac/Scripts/build-libmpv.sh",
            },
            "android_apk": {
                "project_source": project_archive.name,
                "dependency_lock": "OKVideoMac/Helpers/AndroidDexBridge/app/gradle.lockfile",
                "fongmi_upstream_commit": "5fdff00a602dc56e8ba756174daef20edab024f2",
                "fongmi_filtered_source": fongmi_subset_name,
                "fongmi_filtered_source_sha256": subset_sha,
                "mpl_covered_source": "juniversalchardet-1.0.3-sources.jar",
                "mpl_covered_source_sha256": "3d1cb067f5cfe3cc19b77c837156f22368462af9acac5dd878e785966758fc27",
            },
            "node": {
                "binary_distribution_archive_sha256": "e0f383a215dd3093de6d2c74f87056dc2306a2e09ad494cbffdba28f89046f56",
                "source": "node-v22.23.0.tar.gz",
                "source_sha256": "61fd42cd1c3ff04a849f5ad5d08c58b111831944b5b94bc90fc623eab41418a2",
            },
            "native": {"lock": "ThirdParty/native-lock.json", "status": "see native lock and Phase 2 provenance report"},
        },
        "locked_inputs": locked_inputs,
    }
    index_path = output / f"{base}-SOURCE_RELEASE_INDEX.json"
    atomic_json(index_path, index)

    manifest = dict(index)
    manifest["source_release_index"] = {
        "filename": index_path.name,
        "sha256": sha256(index_path),
    }
    output_artifacts = [project_archive, third_party_archive, licenses_archive, index_path]
    if args.binary:
        binary = Path(args.binary).expanduser().resolve()
        if not binary.is_file():
            fail(f"Binary release artifact does not exist: {binary}")
        if f"-{version}-" not in binary.name:
            fail(f"Binary filename does not match release version {version}: {binary.name}")
        bound_apk = Path(args.apk).expanduser().resolve() if args.apk else None
        verify_binary_binding(binary, index_path, bound_apk)
        manifest["binary"] = {"filename": binary.name, "sha256": sha256(binary)}
        output_artifacts.insert(0, binary)
    if args.apk:
        apk = Path(args.apk).expanduser().resolve()
        if not apk.is_file():
            fail(f"APK artifact does not exist: {apk}")
        manifest["apk"] = {"filename": apk.name, "sha256": sha256(apk)}
    if args.sbom:
        sboms = []
        for value in args.sbom:
            sbom = Path(value).expanduser().resolve()
            if not sbom.is_file():
                fail(f"SBOM does not exist: {sbom}")
            sboms.append({"filename": sbom.name, "sha256": sha256(sbom)})
        manifest["sbom"] = sboms
    manifest_path = output / f"{base}-SOURCE_RELEASE_MANIFEST.json"
    atomic_json(manifest_path, manifest)
    output_artifacts.append(manifest_path)

    sums = output / f"{base}-SHA256SUMS"
    sum_lines = [f"{sha256(path)}  {path.name}" for path in output_artifacts]
    sums.write_text("\n".join(sum_lines) + "\n", encoding="utf-8")
    print(f"Source release created at {output}")
    for path in output_artifacts + [sums]:
        print(f"{sha256(path)}  {path.name}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--cache-dir", required=True)
    parser.add_argument("--commit", default="HEAD")
    parser.add_argument("--binary")
    parser.add_argument("--apk")
    parser.add_argument("--sbom", action="append")
    parser.add_argument("--offline", action="store_true")
    make_source_release(parser.parse_args())


if __name__ == "__main__":
    main()
