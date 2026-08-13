#!/usr/bin/env python3
"""Inventory and provenance-classify every Mach-O in an OKVideoMac bundle."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys


FFMPEG_OUTPUTS = {
    "libavcodec.61.dylib",
    "libavfilter.10.dylib",
    "libavformat.61.dylib",
    "libavutil.59.dylib",
    "libswresample.5.dylib",
    "libswscale.8.dylib",
}

COMPONENTS = {
    "OKVideoMac": ("OKVideoMac", "0.3.41 (62)", "project Git commit", None, "A", "Xcode Release recipe verified"),
    "libOKMPVBridge.dylib": ("OKMPVBridge", "project", "project Git commit", None, "A", "source and clang recipe verified with bridge smoke"),
    "libOKQuickJS.dylib": ("QuickJS + OKQuickJSBridge", "2025-09-13-2", "quickjs-2025-09-13-2.tar.xz", "996c6b5018fc955ad4d06426d0e9cb713685a00c825aa5c0418bd53f7df8b0b4", "A", "exact source, locked recipe, rebuild and smoke verified"),
    "libmpv.dylib": ("mpv", "0.41.0", "mpv-v0.41.0.tar.gz + project patch", "ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209", "A", "exact source/patch, Meson recipe, rebuild and ABI smoke verified"),
    "libass.9.dylib": ("libass", "0.17.5", "libass-0.17.5.tar.gz", "fa286fc9ee1ba3b932703a3df7b8474d01dc8abe29ec69b6fa68781dc4bf7acc", "B", "exact source and MacPorts receipt/Portfile locked; full replay pending"),
    "libharfbuzz.0.dylib": ("HarfBuzz", "14.2.1", "harfbuzz-14.2.1.tar.xz", "a54a5d8e9380a41fbb762ce367bcbf7704792dfca0d93f1bbca86c5a57902e0e", "B", "exact source and MacPorts receipt/Portfile locked; full replay pending"),
    "libplacebo.360.dylib": ("libplacebo", "7.360.1", "v7.360.1.tar.gz", "d05fdf90bea2f629eaa2d115e909fd356388ac639e54f77b87a018a6d76224bd", "B", "exact source and receipt/Portfile locked"),
    "libfreetype.6.dylib": ("FreeType", "2.14.3", "freetype-2.14.3.tar.xz", "36bc4f1cc413335368ee656c42afca65c5a3987e8768cc28cf11ba775e785a5f", "B", "exact source and receipt/Portfile locked"),
    "libfribidi.0.dylib": ("FriBidi", "1.0.16", "fribidi-1.0.16.tar.xz", "1b1cde5b235d40479e91be2f0e88a309e3214c8ab470ec8a2744d82a5a9ea05c", "B", "exact source and receipt/Portfile locked"),
    "libbrotlicommon.1.dylib": ("Brotli", "1.2.0", "v1.2.0.tar.gz", "816c96e8e8f193b40151dad7e8ff37b1221d019dbcb9c35cd3fadbfe6477dfec", "B", "exact source and receipt/Portfile locked"),
    "libbrotlidec.1.dylib": ("Brotli", "1.2.0", "v1.2.0.tar.gz", "816c96e8e8f193b40151dad7e8ff37b1221d019dbcb9c35cd3fadbfe6477dfec", "B", "exact source and receipt/Portfile locked"),
    "liblcms2.2.dylib": ("Little CMS 2", "2.19.1", "lcms2-2.19.1.tar.gz", "bfc54f7bab59fbc921012014a8032e4cba4abd46db47d46b76416a8c0b2815c8", "B", "exact source and receipt/Portfile locked"),
    "libpng16.16.dylib": ("libpng", "1.6.58", "libpng-1.6.58.tar.xz", "28eb403f51f0f7405249132cecfe82ea5c0ef97f1b32c5a65828814ae0d34775", "B", "exact source and receipt/Portfile locked"),
    "libjpeg.8.dylib": ("libjpeg-turbo", "3.2.0", "libjpeg-turbo-3.2.0.tar.gz", "6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e", "B", "exact source and receipt/Portfile locked"),
    "liblzma.5.dylib": ("XZ/liblzma", "5.8.3", "xz-5.8.3.tar.bz2", "33bf69c0d6c698e83a68f77e6c1f465778e418ca0b3d59860d3ab446f4ac99a6", "B", "exact source and receipt/Portfile locked"),
    "libiconv.2.dylib": ("GNU libiconv", "1.18", "libiconv-1.18.tar.gz", "3b08f5f4f9b4eb82f151a7040bfd6fe6c6fb922efe4b1659c66ea933276965e8", "B", "exact source and receipt/Portfile locked"),
    "libbz2.1.0.dylib": ("bzip2", "1.0.8", "bzip2-1.0.8.tar.gz", "ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269", "B", "exact source and receipt/Portfile locked"),
    "libsqlite3.dylib": ("SQLite", "3.53.4", "sqlite-autoconf-3530400.tar.gz", "0e9483900e92cd5de8fd48d16bf9200145a61f7fd5be542a5ac81d8a9516eb9c", "B", "exact source and receipt/Portfile locked"),
    "libz.1.dylib": ("zlib", "1.3.2", "historical receipt; original archive unavailable", "d7a0654783a4da529d1bb793b7ad9c3318020af77667bcae35f95d0e42a792f3", "C", "receipt and expected hash retained; exact historical archive unavailable"),
    "libc++.1.0.dylib": ("MacPorts libc++", "11.1.0", "historical clang-11 copied output", None, "C", "receipt retained; historical compiler source/configuration incomplete"),
    "libc++abi.1.dylib": ("MacPorts libc++abi", "11.1.0", "historical clang-11 copied output", None, "C", "receipt retained; historical compiler source/configuration incomplete"),
    "node": ("Node.js", "22.23.0", "node-v22.23.0.tar.gz", "61fd42cd1c3ff04a849f5ad5d08c58b111831944b5b94bc90fc623eab41418a2", "B", "official binary and source locked; local source rebuild not required or replayed"),
}


def run(*args: str, check: bool = True) -> str:
    env = os.environ.copy()
    env["LC_ALL"] = "C"
    result = subprocess.run(args, text=True, capture_output=True, env=env)
    if check and result.returncode:
        raise RuntimeError(f"{' '.join(args)}: {result.stderr.strip()}")
    return (result.stdout + result.stderr).strip()


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def macho_files(app: pathlib.Path) -> list[pathlib.Path]:
    files = []
    for path in (app / "Contents").rglob("*"):
        if path.is_file() and "Mach-O" in run("file", str(path), check=False):
            files.append(path)
    return sorted(files, key=lambda item: item.relative_to(app).as_posix())


def rpaths(path: pathlib.Path) -> list[str]:
    lines = run("otool", "-l", str(path)).splitlines()
    values = []
    for index, line in enumerate(lines):
        if line.strip() == "cmd LC_RPATH":
            for candidate in lines[index + 1:index + 5]:
                match = re.search(r"\bpath (.+?) \(offset", candidate)
                if match:
                    values.append(match.group(1))
                    break
    return values


def linked(path: pathlib.Path) -> list[str]:
    lines = run("otool", "-L", str(path)).splitlines()[1:]
    return [line.strip() for line in lines if line.strip()]


def install_name(path: pathlib.Path) -> str | None:
    output = run("otool", "-D", str(path), check=False).splitlines()
    return output[1].strip() if len(output) > 1 else None


def symbols(path: pathlib.Path) -> tuple[int, str]:
    output = run("nm", "-gjU", str(path), check=False)
    values = sorted(set(line for line in output.splitlines() if line))
    payload = ("\n".join(values) + ("\n" if values else "")).encode()
    return len(values), hashlib.sha256(payload).hexdigest()


def signature(path: pathlib.Path) -> dict[str, object]:
    verify = subprocess.run(
        ["codesign", "--verify", "--strict", str(path)],
        text=True,
        capture_output=True,
        env={**os.environ, "LC_ALL": "C"},
    )
    detail = run("codesign", "-dvv", str(path), check=False)
    identity = re.search(r"^Authority=(.+)$", detail, re.MULTILINE)
    team = re.search(r"^TeamIdentifier=(.+)$", detail, re.MULTILINE)
    flags = re.search(r"^CodeDirectory .* flags=([^\n]+)$", detail, re.MULTILINE)
    return {
        "valid": verify.returncode == 0,
        "authority": identity.group(1) if identity else None,
        "team_id": team.group(1) if team else None,
        "flags": flags.group(1).strip() if flags else None,
    }


def component_for(path: pathlib.Path) -> tuple[str, str, str, str | None, str, str]:
    name = path.name
    if name in FFMPEG_OUTPUTS:
        return (
            "FFmpeg",
            "7.1.4",
            "ffmpeg-7.1.4.tar.xz",
            "71f4aac3573ed9060489cb62526a6c7dda815ae10993789611acd7be9fa9fbf4",
            "A",
            "exact source/configuration, clean rebuild, symbols and capability smoke verified",
        )
    return COMPONENTS.get(name, ("UNKNOWN", "UNKNOWN", "UNKNOWN", None, "D", "no source mapping"))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    args = parser.parse_args()
    app = args.app.resolve()
    entries = []
    for path in macho_files(app):
        component, version, source, source_hash, level, basis = component_for(path)
        symbol_count, symbol_hash = symbols(path)
        entries.append({
            "path": path.relative_to(app).as_posix(),
            "sha256": sha256(path),
            "architecture": run("lipo", "-archs", str(path)).split(),
            "install_name": install_name(path),
            "linked_dylibs": linked(path),
            "rpaths": rpaths(path),
            "exported_symbol_count": symbol_count,
            "exported_symbols_sha256": symbol_hash,
            "signature": signature(path),
            "source_component": component,
            "source_version": version,
            "source_archive": source,
            "source_archive_sha256": source_hash,
            "provenance_level": level,
            "provenance_basis": basis,
        })
    counts = {level: sum(item["provenance_level"] == level for item in entries) for level in "ABCD"}
    result = {
        "schema": 1,
        "release": "OKVideoMac 0.3.41 (62)",
        "audit_date": "2026-08-13",
        "app_sha_scope": "individual Mach-O files; bundle xattrs excluded",
        "macho_count": len(entries),
        "provenance_level_counts": counts,
        "entries": entries,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(f"Inventoried {len(entries)} Mach-O files: {counts}")
    if len(entries) != 28 or counts["D"]:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
