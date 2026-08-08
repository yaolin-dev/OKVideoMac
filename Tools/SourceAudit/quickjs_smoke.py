#!/usr/bin/env python3
"""Allowlist-gated QuickJS source smoke tests in isolated child processes.

The worker exposes only the repository's HTTP callback to JavaScript: there is no
filesystem, shell, native module, or environment API inside QuickJS.  Each source
runs in its own child process, temporary working directory, memory-limited runtime,
and wall-clock timeout.  Public output contains no response bodies or URLs.
"""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import source_audit as audit  # noqa: E402


ALLOWLIST = Path(__file__).resolve().parent / "allowlist.json"
PUBLIC_RESULTS = audit.REPORTS / "dynamic_quickjs_results.json"
PRIVATE_RESULTS = audit.PRIVATE / "dynamic_quickjs"
DYLIB = audit.ROOT / "OKVideoMac/macOS/OKVideoMac/Vendor/Build/QuickJS/lib/libOKQuickJS.dylib"
MAX_RESPONSE = 8 * 1024 * 1024


def safe_wire_url(value: str) -> str:
    parsed = urllib.parse.urlsplit(value)
    return urllib.parse.urlunsplit(
        (
            parsed.scheme,
            parsed.netloc,
            urllib.parse.quote(parsed.path, safe="/%:@!$&'()*+,;=-._~"),
            urllib.parse.quote(parsed.query, safe="=&%:@!$'()*+,;/?-._~"),
            "",
        )
    )


def summary(value: Any) -> dict[str, Any]:
    if value is None:
        return {"type": "null"}
    if isinstance(value, bool):
        return {"type": "boolean", "value": value}
    if isinstance(value, (int, float)):
        return {"type": "number"}
    if isinstance(value, str):
        try:
            nested = json.loads(value)
        except Exception:
            return {"type": "string", **(audit.digest_text(value) or {})}
        result = summary(nested)
        result["encoded_as_json_string"] = True
        result["encoded_string_digest"] = audit.digest_text(value)
        return result
    if isinstance(value, list):
        return {"type": "array", "count": len(value)}
    if isinstance(value, dict):
        result: dict[str, Any] = {"type": "object", "keys": sorted(map(str, value.keys()))}
        for key in ("list", "class", "filters"):
            if isinstance(value.get(key), list):
                result[f"{key}_count"] = len(value[key])
        if isinstance(value.get("url"), str):
            result["has_url"] = bool(value["url"])
            parsed = urllib.parse.urlsplit(value["url"])
            result["url_is_loopback_proxy"] = (parsed.hostname or "").lower() in {"127.0.0.1", "localhost", "::1"}
        return result
    return {"type": type(value).__name__}


def first_video_id(values: list[Any]) -> str | None:
    for value in values:
        if isinstance(value, str):
            try:
                value = json.loads(value)
            except Exception:
                pass
        if not isinstance(value, dict) or not isinstance(value.get("list"), list):
            continue
        for item in value["list"]:
            if isinstance(item, dict) and item.get("vod_id") is not None:
                return str(item["vod_id"])
    return None


def first_category(value: Any) -> str | None:
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except Exception:
            pass
    if not isinstance(value, dict) or not isinstance(value.get("class"), list):
        return None
    for item in value["class"]:
        if isinstance(item, dict) and item.get("type_id") is not None:
            return str(item["type_id"])
    return None


def first_play_reference(value: Any) -> tuple[str, str] | None:
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except Exception:
            pass
    if not isinstance(value, dict) or not isinstance(value.get("list"), list) or not value["list"]:
        return None
    item = value["list"][0]
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


class NativeQuickJS:
    def __init__(self, payload: dict[str, Any]) -> None:
        self.payload = payload
        self.network_count = 0
        self.request_metadata: list[dict[str, Any]] = []
        self.logs: list[str] = []
        self.libc = ctypes.CDLL(None)
        self.libc.malloc.argtypes = [ctypes.c_size_t]
        self.libc.malloc.restype = ctypes.c_void_p
        self.library = ctypes.CDLL(str(DYLIB))
        self.request_callback_type = ctypes.CFUNCTYPE(
            ctypes.c_void_p, ctypes.c_void_p, ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)
        )
        self.module_callback_type = ctypes.CFUNCTYPE(
            ctypes.c_void_p, ctypes.c_void_p, ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)
        )
        self.log_callback_type = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_char_p)
        self.request_callback = self.request_callback_type(self._request)
        self.module_callback = self.module_callback_type(self._module)
        self.log_callback = self.log_callback_type(self._log)
        self.library.okqjs_create.argtypes = [
            ctypes.c_size_t,
            self.request_callback_type,
            self.module_callback_type,
            self.log_callback_type,
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_void_p),
        ]
        self.library.okqjs_create.restype = ctypes.c_void_p
        self.library.okqjs_load.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint64, ctypes.POINTER(ctypes.c_void_p)]
        self.library.okqjs_load.restype = ctypes.c_int
        self.library.okqjs_invoke.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint64, ctypes.POINTER(ctypes.c_void_p)]
        self.library.okqjs_invoke.restype = ctypes.c_void_p
        self.library.okqjs_destroy.argtypes = [ctypes.c_void_p]
        self.library.okqjs_free_string.argtypes = [ctypes.c_void_p]
        self.runtime: int | None = None

    def allocate(self, value: str | bytes) -> int:
        data = value.encode("utf-8") if isinstance(value, str) else value
        pointer = self.libc.malloc(len(data) + 1)
        if not pointer:
            raise MemoryError
        ctypes.memmove(pointer, data, len(data))
        ctypes.memset(pointer + len(data), 0, 1)
        return int(pointer)

    def error(self, error_out: Any, message: str) -> int:
        error_out[0] = self.allocate(message)
        return 0

    def _request(self, opaque: Any, raw_json: bytes | None, error_out: Any) -> int:
        del opaque
        try:
            if self.network_count >= 16:
                return self.error(error_out, "audit network request limit reached")
            self.network_count += 1
            value = json.loads((raw_json or b"null").decode("utf-8"))
            if isinstance(value, str):
                raw_url, options = value, {}
            elif isinstance(value, dict) and isinstance(value.get("url"), str):
                raw_url, options = value["url"], value
            else:
                return self.error(error_out, "audit request must contain URL")
            parsed = urllib.parse.urlsplit(raw_url)
            if parsed.scheme.lower() not in {"http", "https"} or (parsed.hostname or "").lower() in {"127.0.0.1", "localhost", "::1"}:
                return self.error(error_out, "audit allows only non-loopback HTTP/HTTPS")
            method = str(options.get("method") or "GET").upper()
            if method not in {"GET", "POST", "HEAD"}:
                return self.error(error_out, "audit method is not allowlisted")
            headers = {}
            if isinstance(options.get("headers"), dict):
                for key, item in options["headers"].items():
                    if str(key).lower() not in {"cookie", "authorization", "proxy-authorization"} and isinstance(item, (str, int, float)):
                        headers[str(key)] = str(item)
            body: bytes | None = None
            if isinstance(options.get("body"), str):
                body = options["body"].encode("utf-8")
            elif isinstance(options.get("data"), str):
                body = options["data"].encode("utf-8")
            elif isinstance(options.get("data"), dict):
                body = json.dumps(options["data"], ensure_ascii=False, separators=(",", ":")).encode("utf-8")
                headers.setdefault("Content-Type", "application/json")
            self.request_metadata.append(
                {
                    "url_sha256": hashlib.sha256(raw_url.encode()).hexdigest(),
                    "host": parsed.hostname,
                    "method": method,
                    "has_sensitive_headers": any(str(k).lower() in {"cookie", "authorization"} for k in (options.get("headers") or {})),
                }
            )
            if raw_url == self.payload["rule_url"]:
                data = Path(self.payload["rule_path"]).read_bytes()
                response_object = {"code": 200, "headers": {"Content-Type": "application/javascript"}, "content": data.decode("utf-8-sig")}
                return self.allocate(json.dumps(response_object, ensure_ascii=False, separators=(",", ":")))
            request = urllib.request.Request(safe_wire_url(raw_url), data=body, headers=headers, method=method)
            try:
                with urllib.request.urlopen(request, timeout=18) as response:
                    status = getattr(response, "status", 200)
                    data = response.read(MAX_RESPONSE + 1)
                    response_headers = dict(response.headers.items())
            except urllib.error.HTTPError as error:
                status = error.code
                data = error.read(MAX_RESPONSE + 1)
                response_headers = dict(error.headers.items()) if error.headers else {}
            if len(data) > MAX_RESPONSE:
                return self.error(error_out, "audit response exceeded 8 MiB")
            response_object = {"code": status, "headers": response_headers}
            try:
                response_object["content"] = data.decode("utf-8")
            except UnicodeDecodeError:
                import base64

                response_object["content"] = ""
                response_object["base64"] = base64.b64encode(data).decode("ascii")
            time.sleep(0.2)
            return self.allocate(json.dumps(response_object, ensure_ascii=False, separators=(",", ":")))
        except Exception as error:
            return self.error(error_out, f"audit request failure: {type(error).__name__}")

    def _module(self, opaque: Any, raw_name: bytes | None, error_out: Any) -> int:
        del opaque
        name = (raw_name or b"").decode("utf-8", errors="replace")
        for item in self.payload.get("modules") or []:
            aliases = set(item.get("aliases") or [])
            aliases.add(item.get("url") or "")
            relative_match = any(
                alias.startswith("./") and name.endswith("/" + alias[2:])
                for alias in aliases
            )
            if name in aliases or relative_match:
                try:
                    return self.allocate(Path(item["path"]).read_bytes())
                except Exception as error:
                    return self.error(error_out, f"audit cached module failure: {type(error).__name__}")
        return self.error(error_out, "audit module is not present in static allowlist cache")

    def _log(self, opaque: Any, raw_message: bytes | None) -> None:
        del opaque
        message = (raw_message or b"").decode("utf-8", errors="replace")
        self.logs.append(message[:4096])

    def take(self, pointer: int | None) -> str | None:
        if not pointer:
            return None
        try:
            return ctypes.string_at(pointer).decode("utf-8", errors="replace")
        finally:
            self.library.okqjs_free_string(pointer)

    def create_and_load(self) -> None:
        error = ctypes.c_void_p()
        self.runtime = self.library.okqjs_create(
            64 * 1024 * 1024,
            self.request_callback,
            self.module_callback,
            self.log_callback,
            None,
            ctypes.byref(error),
        )
        if not self.runtime:
            raise RuntimeError(self.take(error.value) or "create failed")
        script = Path(self.payload["runtime_path"]).read_bytes()
        source_name = self.payload["runtime_url"].encode("utf-8")
        result = self.library.okqjs_load(self.runtime, script, source_name, 10_000, ctypes.byref(error))
        if result != 0:
            raise RuntimeError(self.take(error.value) or "load failed")

    def invoke(self, method: str, arguments: list[Any]) -> Any:
        error = ctypes.c_void_p()
        encoded = json.dumps(arguments, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        started = time.monotonic()
        pointer = self.library.okqjs_invoke(self.runtime, method.encode(), encoded, 10_000, ctypes.byref(error))
        elapsed = round((time.monotonic() - started) * 1000)
        text = self.take(pointer)
        if text is None:
            raise RuntimeError((self.take(error.value) or "invoke failed") + f" [{elapsed}ms]")
        return json.loads(text), text, elapsed

    def destroy(self) -> None:
        if self.runtime:
            self.library.okqjs_destroy(self.runtime)
            self.runtime = None


def worker(payload: dict[str, Any]) -> dict[str, Any]:
    native = NativeQuickJS(payload)
    methods = []
    raw_results: dict[str, str] = {}
    values: dict[str, Any] = {}
    try:
        native.create_and_load()
        calls: list[tuple[str, list[Any]]] = [("init", [payload["rule_url"]]), ("home", [True]), ("homeVod", [])]
        if payload.get("searchable", True):
            calls.append(("search", ["测试", False, "1"]))
        for method, arguments in calls:
            started = time.monotonic()
            try:
                value, raw, elapsed = native.invoke(method, arguments)
                values[method] = value
                raw_results[method] = raw
                methods.append({"method": method, "status": "success", "elapsed_ms": elapsed, "response": summary(value)})
            except Exception as error:
                methods.append({"method": method, "status": "failed", "elapsed_ms": round((time.monotonic() - started) * 1000), "error_type": type(error).__name__, "error_digest": audit.digest_text(str(error))})
                if method == "init":
                    break
        category_id = first_category(values.get("home"))
        if category_id:
            try:
                value, raw, elapsed = native.invoke("category", [category_id, "1", False, {}])
                values["category"] = value
                raw_results["category"] = raw
                methods.append({"method": "category", "status": "success", "elapsed_ms": elapsed, "response": summary(value)})
            except Exception as error:
                methods.append({"method": "category", "status": "failed", "error_type": type(error).__name__, "error_digest": audit.digest_text(str(error))})
        video_id = first_video_id([values.get("homeVod"), values.get("category"), values.get("search")])
        if video_id:
            try:
                value, raw, elapsed = native.invoke("detail", [video_id])
                values["detail"] = value
                raw_results["detail"] = raw
                methods.append({"method": "detail", "status": "success", "elapsed_ms": elapsed, "response": summary(value)})
            except Exception as error:
                methods.append({"method": "detail", "status": "failed", "error_type": type(error).__name__, "error_digest": audit.digest_text(str(error))})
        play = first_play_reference(values.get("detail"))
        if play:
            try:
                value, raw, elapsed = native.invoke("play", [play[0], play[1], []])
                raw_results["play"] = raw
                methods.append({"method": "play", "status": "success", "elapsed_ms": elapsed, "response": summary(value)})
            except Exception as error:
                methods.append({"method": "play", "status": "failed", "error_type": type(error).__name__, "error_digest": audit.digest_text(str(error))})
    finally:
        native.destroy()
    nonempty = any((item.get("response") or {}).get("list_count", 0) > 0 or (item.get("response") or {}).get("class_count", 0) > 0 or (item.get("response") or {}).get("has_url") for item in methods)
    return {
        "source_id": payload["source_id"],
        "status": "working" if nonempty else ("responding_empty" if any(item["status"] == "success" for item in methods) else "failed"),
        "methods": methods,
        "network_request_count": native.network_count,
        "request_metadata": native.request_metadata,
        "logs": native.logs,
        "raw_results": raw_results,
    }


def active_raw() -> dict[str, Any]:
    records = audit.load_json(audit.PRIVATE / "configuration_records.json")
    record = next(item for item in records if item["is_active"])
    return audit.load_json(audit.ROOT / record["raw_path"])


def orchestrate(execute: bool, timeout: int) -> dict[str, Any]:
    if not execute:
        raise SystemExit("Refusing QuickJS execution without --execute")
    if not DYLIB.is_file():
        raise SystemExit("QuickJS dylib is not built")
    allowlist = audit.load_json(ALLOWLIST)
    allowed_sources = set(allowlist.get("quickjs_source_ids") or [])
    allowed_assets = set(allowlist.get("quickjs_asset_sha256") or [])
    inventory = audit.load_json(audit.REPORTS / "extracted_inventory.json")
    downloads = audit.load_json(audit.REPORTS / "download_manifest.redacted.json")
    private_downloads = {item["asset_id"]: item for item in audit.load_json(audit.PRIVATE / "download_manifest.json")}
    private_assets = {item["asset_id"]: item for item in audit.load_json(audit.PRIVATE / "asset_url_map.json")}
    runtime_item = next(item for item in downloads if item.get("kind") == "javascript" and item.get("sha256") in allowed_assets)
    rule_by_source = {}
    for item in downloads:
        if item.get("kind") == "javascript_rule" and item.get("sha256") in allowed_assets:
            for source_id in item.get("origins") or []:
                rule_by_source[source_id] = item
    raw_sites = {(str(item.get("key") or ""), str(item.get("api") or "")): item for item in active_raw().get("sites", []) if isinstance(item, dict)}
    sources = [item for item in inventory["sources"] if item["source_id"] in allowed_sources and item["referenced_by_active_configuration"] and item["current_provider_type"] == "JavaScriptSpiderSiteProvider"]
    results = []
    for source in sources:
        raw_site = raw_sites[(source["key"], source["api"])]
        rule_item = rule_by_source[source["source_id"]]
        payload = {
            "source_id": source["source_id"],
            "runtime_path": str(audit.ROOT / runtime_item["local_path"]),
            "runtime_url": private_assets[runtime_item["asset_id"]]["url_private"],
            "rule_path": str(audit.ROOT / rule_item["local_path"]),
            "rule_url": str(raw_site.get("ext") or ""),
            "searchable": int(raw_site.get("searchable", 1) or 0) == 1,
            "modules": [
                {
                    "url": private_assets[item["asset_id"]]["url_private"],
                    "aliases": private_assets[item["asset_id"]].get("module_specifiers_private") or [],
                    "path": str(audit.ROOT / item["local_path"]),
                }
                for item in private_downloads.values()
                if item.get("kind") == "javascript_module"
                and item.get("status") == "downloaded"
                and item.get("sha256") in allowed_assets
            ],
        }
        with tempfile.TemporaryDirectory(prefix="okvideo-source-audit-") as temporary:
            environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": temporary, "LANG": "en_US.UTF-8", "PYTHONDONTWRITEBYTECODE": "1"}
            try:
                completed = subprocess.run(
                    [sys.executable, str(Path(__file__).resolve()), "--worker"],
                    input=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    cwd=temporary,
                    env=environment,
                    timeout=timeout,
                    check=False,
                )
                value = json.loads(completed.stdout.decode("utf-8"))
            except subprocess.TimeoutExpired as error:
                value = {"source_id": source["source_id"], "status": "timeout", "methods": [], "worker_timeout_seconds": timeout}
                completed = None
                error_bytes = error.stderr or b""
            except Exception as error:
                value = {"source_id": source["source_id"], "status": "failed", "methods": [], "worker_error_type": type(error).__name__, "worker_error_digest": audit.digest_text(str(error))}
                error_bytes = completed.stderr if "completed" in locals() and completed else b""
            else:
                error_bytes = completed.stderr
        private_dir = PRIVATE_RESULTS / source["source_id"]
        private_dir.mkdir(parents=True, exist_ok=True)
        for method, raw in value.pop("raw_results", {}).items():
            (private_dir / f"{method}.json").write_text(raw, encoding="utf-8")
        logs = value.pop("logs", [])
        (private_dir / "quickjs.log").write_text("\n".join(logs), encoding="utf-8")
        (private_dir / "worker.stderr.log").write_bytes(error_bytes)
        value.update(
            {
                "key": source["key"],
                "name": source["name"],
                "runtime_sha256": runtime_item["sha256"],
                "rule_sha256": rule_item["sha256"],
                "log_lines": len(logs),
                "log_sha256": audit.sha256_bytes("\n".join(logs).encode()),
                "worker_exit_code": completed.returncode if completed else None,
            }
        )
        results.append(value)
    report = {"schema_version": "1.0", "engine": "macOS libOKQuickJS.dylib isolated child process", "source_count": len(results), "timeout_seconds": timeout, "results": results}
    audit.write_json(PUBLIC_RESULTS, report)
    return {
        "sources": len(results),
        "working": sum(item["status"] == "working" for item in results),
        "responding_empty": sum(item["status"] == "responding_empty" for item in results),
        "failed": sum(item["status"] in {"failed", "timeout"} for item in results),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--worker", action="store_true")
    parser.add_argument("--timeout", type=int, default=70)
    args = parser.parse_args()
    if args.worker:
        print(json.dumps(worker(json.loads(sys.stdin.buffer.read().decode("utf-8"))), ensure_ascii=False, separators=(",", ":")))
        return 0
    print(json.dumps(orchestrate(args.execute, args.timeout), ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
