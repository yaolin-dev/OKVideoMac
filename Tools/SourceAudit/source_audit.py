#!/usr/bin/env python3
"""Reproducible, privacy-preserving audit of the installed OKVideoMac sources.

This tool never executes downloaded JavaScript, Jar, Dex, or native code. It only
extracts persisted configuration, downloads direct code assets, and inspects bytes.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import mimetypes
import os
import plistlib
import re
import shutil
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path, PurePosixPath
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parents[2]
CACHE = ROOT / "SourceAuditCache"
PRIVATE = CACHE / "private"
CONFIGS = CACHE / "configs"
JAVASCRIPT = CACHE / "javascript"
JARS = CACHE / "jars"
DEX = CACHE / "dex"
ARCHIVES = CACHE / "archives"
EXTRACTED = CACHE / "extracted"
REPORTS = CACHE / "reports"
LOGS = CACHE / "logs"
DEFAULT_DB = Path.home() / "Library/Application Support/OKVideoMac/Database/OKVideoMac.sqlite3"
DEFAULT_PREFS = Path.home() / "Library/Preferences/com.okvideomac.OKVideoMac.plist"
DEFAULT_CONFIG_DIR = Path.home() / "Library/Application Support/OKVideoMac/Configurations"
MAX_DOWNLOAD = 64 * 1024 * 1024
SENSITIVE_QUERY = re.compile(
    r"token|auth|authorization|cookie|password|passwd|secret|sign|signature|key|code|ticket|session",
    re.I,
)
SENSITIVE_FIELD = re.compile(
    r"token|auth|authorization|cookie|password|passwd|secret|credential|headers?|sign|signature|ticket|session",
    re.I,
)
URL_RE = re.compile(r"https?://[^\s\"'<>]+", re.I)
JS_IMPORT_RE = re.compile(
    r"(?:^|[;\n])\s*(?:import|export)\s*(?:[^\"';\n]*?\bfrom\s*)?[\"']([^\"']+)[\"']"
)
UPSTREAM_QUICKJS_COMMIT = "5fdff00a602dc56e8ba756174daef20edab024f2"


def ensure_dirs() -> None:
    for path in (PRIVATE, CONFIGS, JAVASCRIPT, JARS, DEX, ARCHIVES, EXTRACTED, REPORTS, LOGS):
        path.mkdir(parents=True, exist_ok=True, mode=0o700)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def md5_bytes(data: bytes) -> str:
    return hashlib.md5(data, usedforsecurity=False).hexdigest()


def digest_text(value: str | None) -> dict[str, Any] | None:
    if value is None:
        return None
    data = value.encode("utf-8", errors="replace")
    return {"length": len(value), "sha256": sha256_bytes(data)}


def redact_value(value: str) -> str:
    raw = value.encode("utf-8", errors="replace")
    return f"<redacted:length={len(value)}:sha256={sha256_bytes(raw)[:12]}>"


def redact_url(value: str | None, *, hide_path: bool = False) -> str | None:
    if not value:
        return value
    try:
        parsed = urllib.parse.urlsplit(value)
    except ValueError:
        return redact_value(value)
    if parsed.scheme.lower() not in {"http", "https"}:
        return redact_value(value)
    host = parsed.hostname or ""
    netloc = host
    if parsed.port:
        netloc = f"{host}:{parsed.port}"
    if hide_path:
        path = "/" + redact_value(parsed.path)
    else:
        path_parts = []
        for segment in parsed.path.split("/"):
            decoded = urllib.parse.unquote(segment)
            if len(decoded) > 48 or SENSITIVE_QUERY.search(decoded):
                path_parts.append(redact_value(decoded))
            else:
                path_parts.append(segment)
        path = "/".join(path_parts)
    query = []
    for key, val in urllib.parse.parse_qsl(parsed.query, keep_blank_values=True):
        # All query values are redacted, even when the key looks harmless.
        query.append((key, redact_value(val)))
    return urllib.parse.urlunsplit(
        (parsed.scheme.lower(), netloc, path, urllib.parse.urlencode(query), "")
    )


def summarize_private(value: Any, field_name: str = "") -> Any:
    if value is None or isinstance(value, (bool, int, float)):
        return value
    if isinstance(value, str):
        if value.startswith(("http://", "https://")):
            return {"redacted_url": redact_url(value), **(digest_text(value) or {})}
        if SENSITIVE_FIELD.search(field_name) or field_name in {"ext", "playUrl"}:
            return digest_text(value)
        return value
    if isinstance(value, list):
        return [summarize_private(item, field_name) for item in value]
    if isinstance(value, dict):
        if SENSITIVE_FIELD.search(field_name):
            encoded = json.dumps(value, ensure_ascii=False, sort_keys=True).encode()
            return {"type": "object", "keys": sorted(map(str, value.keys())), "sha256": sha256_bytes(encoded)}
        return {str(key): summarize_private(item, str(key)) for key, item in value.items()}
    return redact_value(str(value))


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    path.write_text(payload, encoding="utf-8")
    os.chmod(path, 0o600)


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def safe_json(data: bytes) -> Any:
    text = data.decode("utf-8-sig")
    return json.loads(text)


def normalized_reference(value: str | None) -> tuple[str | None, str | None]:
    if not value:
        return None, None
    marker = ";md5;"
    if marker in value:
        url, checksum = value.split(marker, 1)
        return url.strip(), checksum.strip().lower() or None
    return value.strip(), None


def resolve_url(reference: str | None, base_url: str | None) -> str | None:
    if not reference:
        return None
    raw, _ = normalized_reference(reference)
    if not raw:
        return None
    resolved = urllib.parse.urljoin(base_url or "", raw)
    parsed = urllib.parse.urlsplit(resolved)
    return resolved if parsed.scheme.lower() in {"http", "https"} else None


def javascript_reference(site: dict[str, Any], config: dict[str, Any], base_url: str | None) -> str | None:
    candidates: list[str] = []
    extra = site.get("extra")
    if isinstance(extra, dict) and isinstance(extra.get("script"), str):
        candidates.append(extra["script"])
    ext = site.get("ext")
    if isinstance(ext, dict) and isinstance(ext.get("script"), str):
        candidates.append(ext["script"])
    if isinstance(site.get("api"), str):
        candidates.append(site["api"])
    if isinstance(config.get("spider"), str):
        candidates.append(config["spider"])
    for candidate in candidates:
        if ".js" in candidate.lower():
            resolved = resolve_url(candidate, base_url)
            if resolved:
                return resolved
    return None


def javascript_rule_references(site: dict[str, Any], base_url: str | None) -> list[str]:
    """Return separately downloadable JS rule assets referenced by a site's ext.

    The type-3 `api` can be a shared JavaScript runtime while `ext` points at the
    actual per-source rule.  Treating only `api` as an asset would prove the
    engine exists without proving the source definition exists.
    """
    candidates: list[str] = []
    ext = site.get("ext")
    if isinstance(ext, str):
        candidates.append(ext)
    elif isinstance(ext, dict):
        for key in ("script", "url", "rule"):
            value = ext.get(key)
            if isinstance(value, str):
                candidates.append(value)
    resolved: list[str] = []
    for candidate in candidates:
        if ".js" not in candidate.lower():
            continue
        value = resolve_url(candidate, base_url)
        if value and value not in resolved:
            resolved.append(value)
    return resolved


def provider_type(site: dict[str, Any], config: dict[str, Any], base_url: str | None) -> tuple[str, str]:
    site_type = int(site.get("type") or 0)
    api = str(site.get("api") or "")
    if site_type in {0, 1, 4}:
        return "StandardSiteProvider", "S0"
    if site_type == 3 and javascript_reference(site, config, base_url):
        return "JavaScriptSpiderSiteProvider", "S1"
    jar = site.get("jar") if isinstance(site.get("jar"), str) else config.get("spider")
    if site_type == 3 and api.startswith("csp_") and isinstance(jar, str) and jar.strip():
        return "AndroidDexSpiderSiteProvider", "S8"
    return "UnsupportedSiteProvider", "S8"


def source_fingerprint(site: dict[str, Any], config: dict[str, Any], base_url: str | None) -> str:
    material = {
        "key": site.get("key"),
        "type": site.get("type"),
        "api": site.get("api"),
        "jar": site.get("jar") or config.get("spider"),
        "ext": site.get("ext"),
        "playUrl": site.get("playUrl"),
        "script": javascript_reference(site, config, base_url),
    }
    return sha256_bytes(json.dumps(material, ensure_ascii=False, sort_keys=True).encode())


def db_rows(connection: sqlite3.Connection, sql: str) -> list[sqlite3.Row]:
    return list(connection.execute(sql))


def preferences_inventory() -> dict[str, Any]:
    if not DEFAULT_PREFS.is_file():
        return {"exists": False, "keys": []}
    with DEFAULT_PREFS.open("rb") as stream:
        values = plistlib.load(stream)
    keys = []
    for key in sorted(values):
        encoded = repr(values[key]).encode("utf-8", errors="replace")
        keys.append({"key": str(key), "value_type": type(values[key]).__name__, "value_length": len(encoded), "value_sha256": sha256_bytes(encoded)})
    return {"exists": True, "path": "~/Library/Preferences/com.okvideomac.OKVideoMac.plist", "keys": keys, "contains_source_configuration": False}


def extract(db_path: Path) -> dict[str, Any]:
    ensure_dirs()
    if not db_path.is_file():
        raise FileNotFoundError(f"OKVideoMac database not found: {db_path}")
    uri = f"file:{urllib.parse.quote(str(db_path))}?mode=ro"
    connection = sqlite3.connect(uri, uri=True)
    connection.row_factory = sqlite3.Row
    configs = db_rows(connection, "SELECT id,name,source_kind,source_value,base_url,raw_data,updated_at,is_active FROM configurations ORDER BY is_active DESC,updated_at DESC")
    lives = db_rows(connection, "SELECT id,name,source_kind,source_value,base_url,raw_data,updated_at FROM live_sources ORDER BY updated_at DESC")
    history = {row["site_key"]: {"count": row["uses"], "last_used": row["last_used"]} for row in db_rows(connection, "SELECT site_key,count(*) AS uses,max(watched_at) AS last_used FROM history GROUP BY site_key")}
    favorites = {row["site_key"]: row["uses"] for row in db_rows(connection, "SELECT site_key,count(*) AS uses FROM favorites GROUP BY site_key")}
    settings = []
    for row in db_rows(connection, "SELECT key,value FROM settings ORDER BY key"):
        blob = bytes(row["value"])
        settings.append({"key": row["key"], "value_bytes": len(blob), "value_sha256": sha256_bytes(blob)})
    connection.close()

    private_records: list[dict[str, Any]] = []
    public_configs: list[dict[str, Any]] = []
    sources: dict[str, dict[str, Any]] = {}
    assets: dict[str, dict[str, Any]] = {}

    for row in configs:
        raw = bytes(row["raw_data"])
        raw_sha = sha256_bytes(raw)
        raw_path = CONFIGS / f"{raw_sha}.json"
        if not raw_path.exists():
            raw_path.write_bytes(raw)
            os.chmod(raw_path, 0o600)
        try:
            parsed = safe_json(raw)
            parse_error = None
        except Exception as error:  # deterministic error class only
            parsed = {}
            parse_error = type(error).__name__
        source_value = row["source_value"]
        base_url = row["base_url"]
        config_id_hash = sha256_bytes(str(row["id"]).encode())[:16]
        origin = {
            "configuration_id_hash": config_id_hash,
            "name": row["name"],
            "source_kind": row["source_kind"],
            "source_value": redact_url(source_value, hide_path=True) if source_value else None,
            "source_value_digest": digest_text(source_value),
            "base_url": redact_url(base_url, hide_path=True) if base_url else None,
            "raw_sha256": raw_sha,
            "raw_bytes": len(raw),
            "updated_at_epoch": row["updated_at"],
            "is_active": bool(row["is_active"]),
            "parse_error": parse_error,
        }
        public_configs.append(origin)
        private_records.append({**origin, "id": row["id"], "source_value_private": source_value, "base_url_private": base_url, "raw_path": str(raw_path.relative_to(ROOT))})
        if source_value and row["source_kind"] == "remote":
            asset_id = sha256_bytes(("config\0" + source_value).encode())
            assets.setdefault(asset_id, {"asset_id": asset_id, "kind": "remote_configuration", "url_private": source_value, "url": redact_url(source_value, hide_path=True), "url_digest": digest_text(source_value), "origins": []})["origins"].append(config_id_hash)
        if not isinstance(parsed, dict):
            continue
        site_values = parsed.get("sites") if isinstance(parsed.get("sites"), list) else []
        for index, site in enumerate(site_values):
            if not isinstance(site, dict):
                continue
            fingerprint = source_fingerprint(site, parsed, base_url)
            source_id = fingerprint[:16]
            provider, technical = provider_type(site, parsed, base_url)
            api = str(site.get("api") or "")
            jar_ref = site.get("jar") if isinstance(site.get("jar"), str) else parsed.get("spider")
            jar_url, configured_md5 = normalized_reference(jar_ref if isinstance(jar_ref, str) else None)
            resolved_jar = resolve_url(jar_url, base_url)
            js_url = javascript_reference(site, parsed, base_url)
            ext = site.get("ext")
            history_info = history.get(str(site.get("key") or ""), {"count": 0, "last_used": None})
            public_site = {
                "source_id": source_id,
                "key": str(site.get("key") or ""),
                "name": str(site.get("name") or site.get("key") or ""),
                "type": int(site.get("type") or 0),
                "api": redact_url(api) if api.startswith(("http://", "https://")) else api,
                "api_digest": digest_text(api),
                "jar": redact_url(resolved_jar) if resolved_jar else (digest_text(str(jar_ref)) if jar_ref else None),
                "jar_digest": digest_text(resolved_jar or (str(jar_ref) if jar_ref else None)),
                "configured_jar_md5": configured_md5,
                "javascript_url": redact_url(js_url),
                "javascript_url_digest": digest_text(js_url),
                "ext": summarize_private(ext, "ext"),
                "playUrl": summarize_private(site.get("playUrl"), "playUrl"),
                "hide": int(site.get("hide") or 0),
                "enabled": int(site.get("hide") or 0) == 0,
                "current_provider_type": provider,
                "technical_type": technical,
                "is_csp": api.startswith("csp_"),
                "is_javascript": technical == "S1",
                "is_standard_http_api": technical == "S0",
                "needs_jar": provider == "AndroidDexSpiderSiteProvider" and bool(resolved_jar),
                "needs_dex": provider == "AndroidDexSpiderSiteProvider",
                "needs_android_bridge": provider == "AndroidDexSpiderSiteProvider",
                "history_use_count": int(history_info.get("count") or 0),
                "history_last_used_epoch": history_info.get("last_used"),
                "favorite_count": int(favorites.get(str(site.get("key") or ""), 0)),
                "configuration_origins": [{**origin, "site_index": index}],
            }
            if fingerprint in sources:
                sources[fingerprint]["configuration_origins"].append({**origin, "site_index": index})
                sources[fingerprint]["enabled"] = sources[fingerprint]["enabled"] or public_site["enabled"]
            else:
                sources[fingerprint] = public_site
            if js_url:
                asset_id = sha256_bytes(("javascript\0" + js_url).encode())
                assets.setdefault(asset_id, {"asset_id": asset_id, "kind": "javascript", "javascript_role": "runtime", "url_private": js_url, "url": redact_url(js_url), "url_digest": digest_text(js_url), "origins": []})["origins"].append(source_id)
            for rule_url in javascript_rule_references(site, base_url):
                asset_id = sha256_bytes(("javascript_rule\0" + rule_url).encode())
                assets.setdefault(asset_id, {"asset_id": asset_id, "kind": "javascript_rule", "javascript_role": "source_rule", "url_private": rule_url, "url": redact_url(rule_url), "url_digest": digest_text(rule_url), "origins": []})["origins"].append(source_id)
            if resolved_jar and provider == "AndroidDexSpiderSiteProvider":
                asset_id = sha256_bytes(("jar\0" + resolved_jar).encode())
                item = assets.setdefault(asset_id, {"asset_id": asset_id, "kind": "jar", "url_private": resolved_jar, "url": redact_url(resolved_jar), "url_digest": digest_text(resolved_jar), "configured_md5": configured_md5, "origins": []})
                item["origins"].append(source_id)

    public_lives = []
    for row in lives:
        raw = bytes(row["raw_data"])
        raw_sha = sha256_bytes(raw)
        raw_path = CONFIGS / f"live-{raw_sha}.data"
        if not raw_path.exists():
            raw_path.write_bytes(raw)
            os.chmod(raw_path, 0o600)
        public_lives.append({"name": row["name"], "source_kind": row["source_kind"], "source_value": redact_url(row["source_value"], hide_path=True), "source_value_digest": digest_text(row["source_value"]), "base_url": redact_url(row["base_url"], hide_path=True), "raw_sha256": raw_sha, "raw_bytes": len(raw), "updated_at_epoch": row["updated_at"]})

    for item in assets.values():
        item["origins"] = sorted(set(item["origins"]))
    private_asset_map = [{**item} for item in sorted(assets.values(), key=lambda x: x["asset_id"])]
    public_asset_map = [{key: value for key, value in item.items() if key != "url_private"} for item in private_asset_map]
    for source in sources.values():
        source["configuration_origins"].sort(key=lambda value: (not value["is_active"], value["configuration_id_hash"], value["site_index"]))
        source["referenced_by_active_configuration"] = any(origin["is_active"] for origin in source["configuration_origins"])
        source["historical_only"] = not source["referenced_by_active_configuration"]

    result = {
        "schema_version": "1.0",
        "database_path": "~/Library/Application Support/OKVideoMac/Database/OKVideoMac.sqlite3",
        "configuration_loading_evidence": [
            "OKVideoMac/macOS/OKVideoMac/App/AppState.swift:252-264",
            "OKVideoMac/macOS/OKVideoMac/App/AppState.swift:2469-2528",
            "OKVideoMac/macOS/OKVideoMac/Packages/OKVideoKit/Sources/OKVideoPersistence/Database/SQLiteStore.swift:122-153",
        ],
        "configurations": public_configs,
        "live_sources": public_lives,
        "settings": settings,
        "user_defaults": preferences_inventory(),
        "configuration_directory_files": sorted(path.name for path in DEFAULT_CONFIG_DIR.glob("*") if path.is_file()),
        "sources": sorted(sources.values(), key=lambda value: (not value["referenced_by_active_configuration"], not value["enabled"], value["name"], value["key"])),
        "assets": public_asset_map,
        "counts": {
            "stored_configurations": len(configs),
            "active_configurations": sum(bool(row["is_active"]) for row in configs),
            "stored_live_sources": len(lives),
            "deduplicated_sources": len(sources),
            "active_configuration_sources": sum(source["referenced_by_active_configuration"] for source in sources.values()),
            "historical_only_sources": sum(source["historical_only"] for source in sources.values()),
        },
    }
    write_json(PRIVATE / "configuration_records.json", private_records)
    write_json(PRIVATE / "asset_url_map.json", private_asset_map)
    write_json(REPORTS / "extracted_inventory.json", result)
    return result


def target_directory(kind: str) -> Path:
    return {"remote_configuration": CONFIGS, "javascript": JAVASCRIPT, "javascript_rule": JAVASCRIPT, "javascript_module": JAVASCRIPT, "jar": JARS}.get(kind, ARCHIVES)


def fetch_one(asset: dict[str, Any], previous: dict[str, Any] | None) -> dict[str, Any]:
    url = asset["url_private"]
    if previous and previous.get("status") == "downloaded":
        cached = ROOT / previous.get("local_path", "")
        if cached.is_file() and sha256_bytes(cached.read_bytes()) == previous.get("sha256"):
            public_asset = {key: value for key, value in asset.items() if key != "url_private"}
            return {**previous, **public_asset, "cache_reused": True}
    started = time.monotonic()
    parsed_url = urllib.parse.urlsplit(url)
    wire_url = urllib.parse.urlunsplit(
        (
            parsed_url.scheme,
            parsed_url.netloc,
            urllib.parse.quote(parsed_url.path, safe="/%:@!$&'()*+,;=-._~"),
            urllib.parse.quote(parsed_url.query, safe="=&%:@!$'()*+,;/?-._~"),
            "",
        )
    )
    request = urllib.request.Request(wire_url, headers={"User-Agent": "OKVideoMac-SourceAudit/1.0", "Accept": "*/*"})
    try:
        with urllib.request.urlopen(request, timeout=25) as response:
            status = getattr(response, "status", 200)
            final_url = response.geturl()
            content_type = response.headers.get_content_type()
            data = response.read(MAX_DOWNLOAD + 1)
            if len(data) > MAX_DOWNLOAD:
                raise ValueError("download exceeded 64 MiB limit")
    except urllib.error.HTTPError as error:
        return {**{key: value for key, value in asset.items() if key != "url_private"}, "status": "failed", "failure_type": "HTTP", "http_status": error.code, "error": f"HTTP {error.code}", "elapsed_ms": round((time.monotonic() - started) * 1000)}
    except urllib.error.URLError as error:
        reason = type(error.reason).__name__
        return {**{key: value for key, value in asset.items() if key != "url_private"}, "status": "failed", "failure_type": reason, "error": reason, "elapsed_ms": round((time.monotonic() - started) * 1000)}
    except Exception as error:
        return {**{key: value for key, value in asset.items() if key != "url_private"}, "status": "failed", "failure_type": type(error).__name__, "error": type(error).__name__, "elapsed_ms": round((time.monotonic() - started) * 1000)}
    sha = sha256_bytes(data)
    md5 = md5_bytes(data)
    extension = {"remote_configuration": ".json", "javascript": ".js", "javascript_rule": ".js", "javascript_module": ".js", "jar": ".jar"}.get(asset["kind"], "")
    destination = target_directory(asset["kind"]) / f"{sha}{extension}"
    if not destination.exists():
        destination.write_bytes(data)
        os.chmod(destination, 0o600)
    return {
        **{key: value for key, value in asset.items() if key != "url_private"},
        "status": "downloaded",
        "http_status": status,
        "final_url": redact_url(final_url, hide_path=asset.get("kind") == "remote_configuration"),
        "final_url_digest": digest_text(final_url),
        "content_type": content_type or mimetypes.guess_type(destination.name)[0] or "application/octet-stream",
        "size": len(data),
        "sha256": sha,
        "md5": md5,
        "configured_md5_matches": asset.get("configured_md5") in {None, "", md5},
        "local_path": str(destination.relative_to(ROOT)),
        "elapsed_ms": round((time.monotonic() - started) * 1000),
        "cache_reused": False,
    }


def fetch() -> dict[str, Any]:
    ensure_dirs()
    private_assets = load_json(PRIVATE / "asset_url_map.json")
    manifest_path = PRIVATE / "download_manifest.json"
    previous_values = load_json(manifest_path) if manifest_path.exists() else []
    previous = {item["asset_id"]: item for item in previous_values}
    results = []
    for index, asset in enumerate(private_assets):
        results.append(fetch_one(asset, previous.get(asset["asset_id"])))
        if index + 1 < len(private_assets):
            time.sleep(0.5)
    # Discover the ES-module graph from downloaded JavaScript without executing it.
    # A bounded recursive walk is enough for the currently referenced runtime and
    # keeps a malformed or adversarial import graph from expanding indefinitely.
    known_assets = {item["asset_id"]: item for item in private_assets}
    known_results = {item["asset_id"]: item for item in results}
    for _ in range(4):
        discovered: list[dict[str, Any]] = []
        for parent_id, parent in list(known_assets.items()):
            if parent.get("kind") not in {"javascript", "javascript_rule", "javascript_module"}:
                continue
            downloaded = known_results.get(parent_id)
            if not downloaded or downloaded.get("status") != "downloaded":
                continue
            path = ROOT / downloaded["local_path"]
            try:
                source = path.read_text(encoding="utf-8-sig")
            except (OSError, UnicodeError):
                continue
            for specifier in sorted(set(JS_IMPORT_RE.findall(source))):
                if specifier.startswith("assets://js/lib/") and ".." not in PurePosixPath(specifier).parts:
                    relative = specifier[len("assets://") :]
                    module_url = (
                        "https://raw.githubusercontent.com/FongMi/TV/"
                        + UPSTREAM_QUICKJS_COMMIT
                        + "/quickjs/src/main/assets/"
                        + relative
                    )
                else:
                    module_url = urllib.parse.urljoin(parent["url_private"], specifier)
                parsed = urllib.parse.urlsplit(module_url)
                if parsed.scheme.lower() not in {"http", "https"}:
                    continue
                asset_id = sha256_bytes(("javascript_module\0" + module_url).encode())
                if asset_id in known_assets:
                    existing = known_assets[asset_id]
                    existing["origins"] = sorted(set((existing.get("origins") or []) + (parent.get("origins") or [])))
                    aliases = set(existing.get("module_specifiers_private") or [])
                    aliases.add(specifier)
                    existing["module_specifiers_private"] = sorted(aliases)
                    continue
                item = {
                    "asset_id": asset_id,
                    "kind": "javascript_module",
                    "javascript_role": "runtime_module",
                    "url_private": module_url,
                    "url": redact_url(module_url),
                    "url_digest": digest_text(module_url),
                    "module_specifiers_private": [specifier],
                    "module_specifier_digests": [digest_text(specifier)],
                    "origins": sorted(set(parent.get("origins") or [])),
                    "discovered_from_asset_id": parent_id,
                }
                known_assets[asset_id] = item
                discovered.append(item)
        if not discovered:
            break
        for item in discovered:
            result = fetch_one(item, previous.get(item["asset_id"]))
            known_results[item["asset_id"]] = result
            results.append(result)
            time.sleep(0.5)
    private_assets = sorted(known_assets.values(), key=lambda item: item["asset_id"])
    # Private aliases are needed only by the isolated module loader.  Public
    # manifests retain hashes, never a potentially signed module specifier.
    public_results = [
        {key: value for key, value in item.items() if key != "module_specifiers_private"}
        for item in results
    ]
    write_json(PRIVATE / "asset_url_map.json", private_assets)
    write_json(manifest_path, results)
    write_json(REPORTS / "download_manifest.redacted.json", public_results)
    return {"total": len(results), "downloaded": sum(item["status"] == "downloaded" for item in results), "failed": sum(item["status"] != "downloaded" for item in results)}


def command_output(arguments: list[str]) -> str | None:
    executable = shutil.which(arguments[0])
    if not executable:
        return None
    result = subprocess.run([executable, *arguments[1:]], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=15, check=False)
    return result.stdout.decode("utf-8", errors="replace").strip()


def string_markers(data: bytes) -> dict[str, Any]:
    checks = {
        "android": [b"android/", b"android.", b"Landroid/"],
        "androidx": [b"androidx/", b"androidx."],
        "dalvik": [b"dalvik/", b"dalvik.", b"DexClassLoader"],
        "context": [b"android/content/Context", b"Landroid/content/Context;"],
        "activity_ui": [b"android/app/Activity", b"android/view/View", b"android/webkit/WebView", b"WindowManagerGlobal"],
        "shared_preferences": [b"SharedPreferences"],
        "package_manager": [b"PackageManager"],
        "native_load": [b"System.loadLibrary", b"loadLibrary", b"System.load"],
        "java_standard": [b"java/lang/", b"java/util/", b"java/net/"],
        "kotlin": [b"kotlin/", b"kotlinx/"],
        "okhttp": [b"okhttp3/", b"okhttp3."],
        "gson": [b"com/google/gson", b"Gson"],
        "guava": [b"com/google/common"],
        "bouncycastle": [b"org/bouncycastle"],
        "reflection": [b"java/lang/reflect", b"Class.forName", b"getDeclaredMethod"],
        "classloader": [b"ClassLoader", b"loadClass"],
        "dynamic_download": [b"http://", b"https://", b"URLConnection", b"OkHttpClient"],
    }
    return {key: any(marker in data for marker in markers) for key, markers in checks.items()}


def safe_member(name: str) -> bool:
    path = PurePosixPath(name)
    return not path.is_absolute() and ".." not in path.parts


def dex_analysis(path: Path) -> dict[str, Any]:
    sdk_roots = [
        os.environ.get("ANDROID_SDK_ROOT"),
        os.environ.get("ANDROID_HOME"),
        str(Path.home() / "Library/Android/sdk"),
    ]
    candidates: list[Path] = []
    for sdk_root in filter(None, sdk_roots):
        build_tools = Path(sdk_root) / "build-tools"
        if not build_tools.is_dir():
            continue
        for version in sorted(build_tools.iterdir(), reverse=True):
            candidates.append(version / "dexdump")
    tool = next((candidate for candidate in candidates if candidate.is_file()), None)
    if tool is None:
        return {"tool_available": False}
    completed = subprocess.run(
        [str(tool), str(path)],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=30,
        check=False,
    )
    output = completed.stdout.decode("utf-8", errors="replace")
    descriptors = sorted(set(re.findall(r"Class descriptor\s+: '([^']+)'", output)))
    android_types = sorted(set(re.findall(r"L(?:android|androidx|dalvik)/[^;' )]+;", output)))
    spider_prefix = "Lcom/github/catvod/spider/"
    spider_classes = sorted(
        descriptor[len(spider_prefix) : -1]
        for descriptor in descriptors
        if descriptor.startswith(spider_prefix) and "/mergeguard/" not in descriptor
    )
    selected_methods: dict[str, list[dict[str, str]]] = {}
    selected = {
        "Lcom/github/catvod/spider/BaseSpiderGuard;",
        "Lcom/github/catvod/spider/DexNative;",
        "Lcom/github/catvod/spider/Init;",
        "Lcom/github/catvod/spider/Proxy;",
    }
    current_class: str | None = None
    method_section = False
    pending_name: str | None = None
    for line in output.splitlines():
        match = re.search(r"Class descriptor\s+: '([^']+)'", line)
        if match:
            current_class = match.group(1)
            method_section = False
            pending_name = None
            continue
        stripped = line.strip()
        if stripped in {"Direct methods    -", "Virtual methods   -"}:
            method_section = True
            continue
        if stripped in {"Static fields     -", "Instance fields   -", "Interfaces        -"}:
            method_section = False
            pending_name = None
            continue
        if method_section and current_class in selected:
            name_match = re.match(r"name\s+: '([^']+)'", stripped)
            if name_match:
                pending_name = name_match.group(1)
                continue
            type_match = re.match(r"type\s+: '([^']+)'", stripped)
            if type_match and pending_name:
                selected_methods.setdefault(current_class, []).append(
                    {"name": pending_name, "descriptor": type_match.group(1)}
                )
                pending_name = None
    header = command_output([str(tool), "-f", str(path)]) or ""
    sizes = {}
    for key in ("file_size", "string_ids_size", "type_ids_size", "method_ids_size", "class_defs_size"):
        match = re.search(rf"^{key}\s+:\s+(\d+)", header, re.M)
        if match:
            sizes[key] = int(match.group(1))
    return {
        "tool_available": True,
        "tool": str(tool),
        "header_sizes": sizes,
        "class_descriptors": descriptors,
        "spider_classes": spider_classes,
        "android_type_references": android_types,
        "selected_method_signatures": selected_methods,
    }


def archive_analysis(path: Path, sha: str) -> dict[str, Any]:
    result: dict[str, Any] = {"is_zip": zipfile.is_zipfile(path), "entries": [], "entry_counts": {}, "markers": {}}
    if not result["is_zip"]:
        result["markers"] = string_markers(path.read_bytes())
        return result
    combined = bytearray()
    extract_root = EXTRACTED / sha
    extract_root.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path) as archive:
        for info in sorted(archive.infolist(), key=lambda value: value.filename):
            suffix = PurePosixPath(info.filename).suffix.lower()
            kind = {".class": "class", ".dex": "dex", ".so": "so", ".dylib": "dylib", ".dll": "dll", ".aar": "aar", ".apk": "apk"}.get(suffix, "other")
            result["entry_counts"][kind] = result["entry_counts"].get(kind, 0) + 1
            entry = {"name": info.filename, "size": info.file_size, "compressed_size": info.compress_size, "kind": kind}
            if info.file_size <= 32 * 1024 * 1024 and not info.is_dir():
                data = archive.read(info)
                entry["sha256"] = sha256_bytes(data)
                if kind in {"class", "dex", "so", "dylib", "dll", "aar", "apk"}:
                    combined.extend(data[: 8 * 1024 * 1024])
                if kind in {"dex", "so", "dylib", "dll"} and safe_member(info.filename):
                    target = extract_root / info.filename
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(data)
                    os.chmod(target, 0o600)
                    entry["extracted_path"] = str(target.relative_to(ROOT))
                    entry["file_type"] = command_output(["file", "-b", str(target)])
                    if kind == "dex":
                        entry["dex_analysis"] = dex_analysis(target)
                    if kind == "so":
                        entry["objdump_private_headers"] = command_output(["objdump", "-p", str(target)])
            result["entries"].append(entry)
    result["markers"] = string_markers(bytes(combined))
    return result


def classify_asset(item: dict[str, Any], structure: dict[str, Any]) -> dict[str, Any]:
    counts = structure.get("entry_counts", {})
    markers = structure.get("markers", {})
    contains_dex = counts.get("dex", 0) > 0
    contains_so = counts.get("so", 0) > 0
    if item.get("kind") in {"javascript", "javascript_rule", "javascript_module"}:
        technical, level, target = "S1", 0, "KEEP_QUICKJS"
    elif contains_so:
        technical, level, target = "S7", 6, "KEEP_OPTIONAL_ANDROID_FALLBACK"
    elif contains_dex or markers.get("dalvik"):
        technical, level, target = "S6", 6, "KEEP_OPTIONAL_ANDROID_FALLBACK"
    elif markers.get("activity_ui"):
        technical, level, target = "S5", 5, "REWRITE_AUTH_UI"
    elif markers.get("context") or markers.get("shared_preferences") or markers.get("android"):
        technical, level, target = "S4", 4, "JVM_WITH_HOST_SERVICES"
    elif counts.get("class", 0) and not markers.get("android") and not markers.get("androidx"):
        technical, level, target = "S2", 0, "MIGRATE_TO_JVM"
    elif item.get("kind") == "remote_configuration":
        technical, level, target = "CONFIG", 0, "KEEP_NATIVE_API"
    else:
        technical, level, target = "S8", None, "NEED_MORE_EVIDENCE"
    return {"technical_type": technical, "android_dependency_level": level, "recommended_target": target, "contains_dex": contains_dex, "contains_native_so": contains_so}


def analyze() -> dict[str, Any]:
    ensure_dirs()
    downloads = load_json(PRIVATE / "download_manifest.json")
    analyses = []
    for item in downloads:
        if item.get("status") != "downloaded":
            analyses.append({"asset_id": item["asset_id"], "kind": item["kind"], "status": "unavailable", "reason": item.get("error")})
            continue
        path = ROOT / item["local_path"]
        data = path.read_bytes()
        structure = archive_analysis(path, item["sha256"])
        analyses.append({
            "asset_id": item["asset_id"],
            "kind": item["kind"],
            "status": "analyzed",
            "local_path": item["local_path"],
            "sha256": item["sha256"],
            "md5": item["md5"],
            "size": item["size"],
            "file_type": command_output(["file", "-b", str(path)]),
            "structure": structure,
            "classification": classify_asset(item, structure),
            "execution_performed": False,
        })
    write_json(REPORTS / "static_asset_analysis.json", analyses)
    return {"total": len(analyses), "analyzed": sum(item["status"] == "analyzed" for item in analyses), "unavailable": sum(item["status"] != "analyzed" for item in analyses)}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["extract", "fetch", "analyze", "all"])
    parser.add_argument("--database", type=Path, default=DEFAULT_DB)
    args = parser.parse_args()
    ensure_dirs()
    summary: dict[str, Any] = {}
    if args.command in {"extract", "all"}:
        summary["extract"] = extract(args.database)["counts"]
    if args.command in {"fetch", "all"}:
        summary["fetch"] = fetch()
    if args.command in {"analyze", "all"}:
        summary["analyze"] = analyze()
    print(json.dumps(summary, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
