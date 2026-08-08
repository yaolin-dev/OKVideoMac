#!/usr/bin/env python3
"""Allowlist-gated, low-frequency Android Bridge source smoke tests.

Downloaded code is never loaded in this macOS process. Requests are sent only to
the existing Android Bridge loopback endpoint, where Jar/Dex execution is isolated.
Raw responses remain under the Git-ignored private cache.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import source_audit as audit  # noqa: E402


ROOT = audit.ROOT
CACHE = audit.CACHE
PRIVATE_DYNAMIC = audit.PRIVATE / "dynamic_android"
PUBLIC_RESULTS = audit.REPORTS / "dynamic_android_results.json"
ALLOWLIST = Path(__file__).resolve().parent / "allowlist.json"
MAX_RESPONSE = 8 * 1024 * 1024


def write_private(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)
    os.chmod(path, 0o600)


def ext_string(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)


def response_summary(value: Any) -> dict[str, Any]:
    if value is None:
        return {"type": "null"}
    if isinstance(value, bool):
        return {"type": "boolean", "value": value}
    if isinstance(value, (int, float)):
        return {"type": "number"}
    if isinstance(value, str):
        return {"type": "string", **(audit.digest_text(value) or {})}
    if isinstance(value, list):
        return {
            "type": "array",
            "count": len(value),
            "first_item": response_summary(value[0]) if value else None,
        }
    if isinstance(value, dict):
        summary: dict[str, Any] = {"type": "object", "keys": sorted(map(str, value.keys()))}
        for key in ("list", "class", "filters"):
            if isinstance(value.get(key), list):
                summary[f"{key}_count"] = len(value[key])
        for key in ("page", "pagecount", "limit", "total"):
            if isinstance(value.get(key), (int, float, str)):
                summary[key] = str(value[key])[:24]
        if "url" in value:
            summary["has_url"] = bool(value.get("url"))
            if isinstance(value.get("url"), str):
                parsed = urllib.parse.urlsplit(value["url"])
                summary["url_is_loopback_proxy"] = (parsed.hostname or "").lower() in {"127.0.0.1", "localhost", "::1"}
        return summary
    return {"type": type(value).__name__}


def public_ui_state(endpoint: str) -> dict[str, Any] | None:
    try:
        with urllib.request.urlopen(endpoint + "/v1/ui/state", timeout=2) as response:
            value = json.loads(response.read(MAX_RESPONSE).decode("utf-8"))
    except Exception:
        return None
    if not isinstance(value, dict):
        return None
    return {
        "visible": bool(value.get("visible")),
        "input_count": int(value.get("inputCount") or 0),
        "image_count": int(value.get("imageCount") or 0),
        "button_count": len(value.get("buttons") or []),
        "control_count": len(value.get("controls") or []),
        "phase": value.get("phase") if isinstance(value.get("phase"), str) else None,
        "provider": value.get("provider") if isinstance(value.get("provider"), str) else None,
        "authenticated": value.get("authenticated") if isinstance(value.get("authenticated"), bool) else None,
    }


def invoke(endpoint: str, source: dict[str, Any], raw_site: dict[str, Any], jar_reference: str, base_url: str | None, method: str, arguments: list[Any], timeout: float, record_name: str | None = None) -> tuple[dict[str, Any], Any | None]:
    jar_url, jar_md5 = audit.normalized_reference(jar_reference)
    resolved_jar = audit.resolve_url(jar_url, base_url)
    payload = {
        "siteKey": raw_site.get("key") or "",
        "api": raw_site.get("api") or "",
        "ext": ext_string(raw_site.get("ext")),
        "jarURL": resolved_jar or "",
        "jarMD5": jar_md5 or "",
        "method": method,
        "arguments": arguments,
    }
    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    request = urllib.request.Request(endpoint + "/v1/invoke", data=body, headers={"Content-Type": "application/json"}, method="POST")
    started = time.monotonic()
    raw_response: bytes | None = None
    http_status: int | None = None
    failure_type: str | None = None
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            http_status = getattr(response, "status", 200)
            raw_response = response.read(MAX_RESPONSE + 1)
            if len(raw_response) > MAX_RESPONSE:
                raise ValueError("bridge response exceeded 8 MiB")
    except urllib.error.HTTPError as error:
        http_status = error.code
        raw_response = error.read(MAX_RESPONSE)
        failure_type = "HTTPError"
    except Exception as error:
        failure_type = type(error).__name__
    elapsed = round((time.monotonic() - started) * 1000)
    private_dir = PRIVATE_DYNAMIC / source["source_id"]
    raw_path = private_dir / f"{record_name or method}.json"
    if raw_response is not None:
        write_private(raw_path, raw_response)
    parsed: Any | None = None
    bridge_result: Any | None = None
    bridge_ok = False
    error_digest = None
    if raw_response is not None:
        try:
            parsed = json.loads(raw_response.decode("utf-8"))
            if isinstance(parsed, dict):
                bridge_ok = bool(parsed.get("ok")) and (http_status or 0) in range(200, 300)
                bridge_result = parsed.get("result")
                if parsed.get("error") is not None:
                    error_digest = audit.digest_text(str(parsed.get("error")))
        except Exception as error:
            failure_type = type(error).__name__
    ui = public_ui_state(endpoint)
    status = "success" if bridge_ok else "failed"
    if failure_type in {"TimeoutError", "socket.timeout"}:
        status = "timeout"
    if ui and ui.get("visible") and (ui.get("input_count") or ui.get("image_count") or ui.get("button_count") or ui.get("control_count")):
        status = "ui_required" if not bridge_ok else status
    public = {
        "method": method,
        "status": status,
        "http_status": http_status,
        "elapsed_ms": elapsed,
        "failure_type": failure_type,
        "error_digest": error_digest,
        "request": {
            "argument_count": len(arguments),
            "arguments_sha256": audit.sha256_bytes(json.dumps(arguments, ensure_ascii=False, sort_keys=True).encode()),
            "ext": audit.digest_text(payload["ext"]),
            "jar_sha256_expected_from_asset_inventory": source.get("jar_asset_sha256"),
        },
        "response": {
            "bytes": len(raw_response) if raw_response is not None else 0,
            "sha256": audit.sha256_bytes(raw_response) if raw_response is not None else None,
            "summary": response_summary(bridge_result) if parsed is not None else None,
            "private_path": str(raw_path.relative_to(ROOT)) if raw_response is not None else None,
        },
        "ui_state": ui,
    }
    return public, bridge_result


def nonempty_spider_value(value: Any) -> bool:
    if value is None:
        return False
    if isinstance(value, str):
        if not value.strip():
            return False
        try:
            return nonempty_spider_value(json.loads(value))
        except Exception:
            return True
    if isinstance(value, list):
        return bool(value)
    if isinstance(value, dict):
        for key in ("list", "class", "data", "videos"):
            if isinstance(value.get(key), list) and value[key]:
                return True
        return bool(value.get("url"))
    return bool(value)


def proxy_probe(endpoint: str, source: dict[str, Any], timeout: float) -> dict[str, Any]:
    """Probe the Jar-scoped proxy ABI without supplying a media URL or credential."""
    query = urllib.parse.urlencode({"do": "source_audit_probe", "siteKey": source["key"]})
    started = time.monotonic()
    status = None
    body = b""
    failure_type = None
    try:
        with urllib.request.urlopen(endpoint + "/proxy?" + query, timeout=min(timeout, 10)) as response:
            status = getattr(response, "status", 200)
            body = response.read(MAX_RESPONSE + 1)
    except urllib.error.HTTPError as error:
        status = error.code
        body = error.read(MAX_RESPONSE)
        failure_type = "HTTPError"
    except Exception as error:
        failure_type = type(error).__name__
    private_path = PRIVATE_DYNAMIC / source["source_id"] / "proxyLocal.probe"
    if body:
        write_private(private_path, body)
    return {
        "method": "proxyLocal",
        "status": "success" if status is not None and 200 <= status < 300 else "unsupported_or_empty",
        "http_status": status,
        "elapsed_ms": round((time.monotonic() - started) * 1000),
        "failure_type": failure_type,
        "probe_only": True,
        "response": {
            "bytes": len(body),
            "sha256": audit.sha256_bytes(body) if body else None,
            "private_path": str(private_path.relative_to(ROOT)) if body else None,
        },
    }


def first_video_id(values: list[Any]) -> str | None:
    for value in values:
        if not isinstance(value, dict):
            continue
        items = value.get("list")
        if not isinstance(items, list):
            continue
        for item in items:
            if isinstance(item, dict) and item.get("vod_id") is not None:
                return str(item["vod_id"])
    return None


def first_category(value: Any) -> str | None:
    if not isinstance(value, dict) or not isinstance(value.get("class"), list):
        return None
    for item in value["class"]:
        if isinstance(item, dict) and item.get("type_id") is not None:
            return str(item["type_id"])
    return None


def first_play_reference(detail: Any) -> tuple[str, str] | None:
    if not isinstance(detail, dict) or not isinstance(detail.get("list"), list) or not detail["list"]:
        return None
    item = detail["list"][0]
    if not isinstance(item, dict):
        return None
    flags = str(item.get("vod_play_from") or "").split("$$$")
    groups = str(item.get("vod_play_url") or "").split("$$$")
    if not flags or not groups:
        return None
    for episode in groups[0].split("#"):
        if "$" in episode:
            _, reference = episode.split("$", 1)
            if reference:
                return flags[0], reference
    return None


def load_active_raw_configuration() -> tuple[dict[str, Any], dict[str, Any]]:
    records = audit.load_json(audit.PRIVATE / "configuration_records.json")
    record = next(value for value in records if value["is_active"])
    raw = audit.load_json(ROOT / record["raw_path"])
    return record, raw


def bridge_health(endpoint: str) -> dict[str, Any]:
    try:
        with urllib.request.urlopen(endpoint + "/health", timeout=3) as response:
            value = json.loads(response.read(4096).decode("utf-8"))
        return {"ok": bool(value.get("ok")), "version": value.get("version")}
    except Exception as error:
        return {"ok": False, "failure_type": type(error).__name__}


def run(endpoint: str, mode: str, timeout: float, execute: bool, abi_probes: bool) -> dict[str, Any]:
    if not execute:
        raise SystemExit("Refusing dynamic execution without --execute")
    allowlist = audit.load_json(ALLOWLIST)
    allowed = set(allowlist.get("android_bridge_source_ids") or [])
    inventory = audit.load_json(audit.REPORTS / "extracted_inventory.json")
    sources = [value for value in inventory["sources"] if value["source_id"] in allowed and value["referenced_by_active_configuration"] and value["current_provider_type"] == "AndroidDexSpiderSiteProvider"]
    record, config = load_active_raw_configuration()
    raw_sites = {(str(site.get("key") or ""), str(site.get("api") or "")): site for site in config.get("sites", []) if isinstance(site, dict)}
    jar_reference = config.get("spider") or ""
    results = []
    for source in sources:
        raw_site = raw_sites.get((source["key"], source["api"]))
        if raw_site is None:
            results.append({"source_id": source["source_id"], "key": source["key"], "name": source["name"], "status": "skipped", "reason": "raw_site_not_found", "methods": []})
            continue
        methods = []
        home_public, home_value = invoke(endpoint, source, raw_site, jar_reference, record.get("base_url_private"), "home", [True], timeout)
        methods.append(home_public)
        time.sleep(0.35)
        home_vod_public, home_vod_value = invoke(endpoint, source, raw_site, jar_reference, record.get("base_url_private"), "homeVod", [], timeout)
        methods.append(home_vod_public)
        time.sleep(0.35)
        if not nonempty_spider_value(home_value) and not nonempty_spider_value(home_vod_value):
            reset_public, _ = invoke(endpoint, source, raw_site, jar_reference, record.get("base_url_private"), "destroy", [], min(timeout, 10), "destroy_before_home_retry")
            reset_public["phase"] = "home_empty_reset"
            methods.append(reset_public)
            home_public, home_value = invoke(endpoint, source, raw_site, jar_reference, record.get("base_url_private"), "home", [True], timeout, "home_retry")
            home_public["phase"] = "retry_after_empty_home"
            methods.append(home_public)
            time.sleep(0.2)
            home_vod_public, home_vod_value = invoke(endpoint, source, raw_site, jar_reference, record.get("base_url_private"), "homeVod", [], timeout, "homeVod_retry")
            home_vod_public["phase"] = "retry_after_empty_home"
            methods.append(home_vod_public)
            time.sleep(0.2)
        search_value = None
        if int(raw_site.get("searchable", 1) or 0) == 1:
            # Match AppState/AndroidDexSpiderSiteProvider: page 1 deliberately
            # uses the two-argument overload because many CatVod spiders only
            # override that ABI.
            search_public, search_value = invoke(endpoint, source, raw_site, jar_reference, record.get("base_url_private"), "search", ["测试", False], timeout)
            methods.append(search_public)
            time.sleep(0.35)
            if not nonempty_spider_value(search_value):
                reset_public, _ = invoke(endpoint, source, raw_site, jar_reference, record.get("base_url_private"), "destroy", [], min(timeout, 10), "destroy_before_search_retry")
                reset_public["phase"] = "search_empty_reset"
                methods.append(reset_public)
                recovery_home, _ = invoke(endpoint, source, raw_site, jar_reference, record.get("base_url_private"), "home", [True], timeout, "home_before_search_retry")
                recovery_home["phase"] = "search_retry_lifecycle"
                methods.append(recovery_home)
                time.sleep(0.2)
                search_public, search_value = invoke(endpoint, source, raw_site, jar_reference, record.get("base_url_private"), "search", ["测试", False], timeout, "search_retry")
                search_public["phase"] = "retry_after_empty_search"
                methods.append(search_public)
                time.sleep(0.2)
        if abi_probes:
            action_public, _ = invoke(endpoint, source, raw_site, jar_reference, record.get("base_url_private"), "action", [""], min(timeout, 10))
            methods.append(action_public)
            time.sleep(0.2)
            methods.append(proxy_probe(endpoint, source, timeout))
        else:
            methods.append({"method": "action", "status": "not_tested", "reason": "requires_meaningful_allowlisted_action_fixture"})
            methods.append({"method": "proxyLocal", "status": "not_tested", "reason": "requires_meaningful_proxy_parameters"})
        methods.append({"method": "live", "status": "not_tested", "reason": "no_safe_live_url_fixture"})
        deep = mode == "deep-all" or (mode == "deep-used" and int(source.get("history_use_count") or 0) > 0)
        category_value = None
        category_id = first_category(home_value)
        if deep and category_id:
            category_public, category_value = invoke(endpoint, source, raw_site, jar_reference, record.get("base_url_private"), "category", [category_id, "1", True, {}], timeout)
            methods.append(category_public)
            time.sleep(0.35)
        detail_value = None
        video_id = first_video_id([home_vod_value, category_value, search_value])
        if deep and video_id:
            detail_public, detail_value = invoke(endpoint, source, raw_site, jar_reference, record.get("base_url_private"), "detail", [[video_id]], timeout)
            methods.append(detail_public)
            time.sleep(0.35)
        play_reference = first_play_reference(detail_value)
        if deep and play_reference:
            play_public, _ = invoke(endpoint, source, raw_site, jar_reference, record.get("base_url_private"), "play", [play_reference[0], play_reference[1], []], timeout)
            methods.append(play_public)
            time.sleep(0.35)
        destroy_public, _ = invoke(endpoint, source, raw_site, jar_reference, record.get("base_url_private"), "destroy", [], min(timeout, 10))
        methods.append(destroy_public)
        success_methods = [value["method"] for value in methods if value["status"] == "success"]
        nonempty = any((value.get("response", {}).get("summary") or {}).get("list_count", 0) > 0 or (value.get("response", {}).get("summary") or {}).get("class_count", 0) > 0 or (value.get("response", {}).get("summary") or {}).get("has_url") for value in methods)
        results.append({
            "source_id": source["source_id"],
            "key": source["key"],
            "name": source["name"],
            "history_use_count": source.get("history_use_count", 0),
            "status": "working" if nonempty else ("responding_empty" if success_methods else "failed"),
            "success_methods": success_methods,
            "methods": methods,
        })
    report = {
        "schema_version": "1.0",
        "engine": "existing Android Bridge in emulator",
        "endpoint": endpoint,
        "mode": mode,
        "timeout_seconds": timeout,
        "bridge_health": bridge_health(endpoint),
        "abi_probes_enabled": abi_probes,
        "allowlist_path": str(ALLOWLIST.relative_to(ROOT)),
        "source_count": len(results),
        "results": results,
    }
    audit.write_json(PUBLIC_RESULTS, report)
    return {"sources": len(results), "working": sum(value["status"] == "working" for value in results), "responding_empty": sum(value["status"] == "responding_empty" for value in results), "failed": sum(value["status"] == "failed" for value in results)}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint", default="http://127.0.0.1:9978")
    parser.add_argument("--mode", choices=["home-search", "deep-used", "deep-all"], default="deep-used")
    parser.add_argument("--timeout", type=float, default=25)
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--abi-probes", action="store_true")
    args = parser.parse_args()
    print(json.dumps(run(args.endpoint, args.mode, args.timeout, args.execute, args.abi_probes), ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
