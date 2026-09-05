#!/usr/bin/env python3
"""Local, deterministic documentation source for OKVideoMac 0.4.0 screenshots.

This server exposes a standard type-1 VOD API plus an M3U live playlist. Every
title, person, studio, poster and media file is a fictional project fixture.
It binds to loopback by default and never contacts the public internet.
"""

from __future__ import annotations

import argparse
import json
import mimetypes
import re
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, urlparse


ROOT = Path(__file__).resolve().parent
CATALOG = json.loads((ROOT / "catalog.json").read_text(encoding="utf-8"))
ITEMS = CATALOG["items"]
CATEGORIES = CATALOG["categories"]
ASSETS = ROOT / "assets"
PAGE_SIZE = 12


def episode_name(number: int, total: int) -> str:
    if total == 1:
        return "正片"
    if total >= 100:
        return f"第 {number:03d} 集"
    return f"第 {number:02d} 集"


def public_item(item: dict, origin: str, include_detail: bool = False) -> dict:
    result = {
        "vod_id": item["id"],
        "vod_name": item["title"],
        "vod_en": item["alternateTitle"],
        "vod_pic": f"{origin}/assets/posters/{quote(item['id'])}.jpg",
        "vod_year": item["year"],
        "vod_area": item["region"],
        "vod_class": ",".join(item["genres"]),
        "vod_remarks": item["remarks"],
        "vod_score": item["rating"],
        "type_id": item["category"],
        "type_name": next(
            category["name"] for category in CATEGORIES if category["id"] == item["category"]
        ),
    }
    if include_detail:
        media_url = f"{origin}/media/demo-landscape.mp4"
        episodes = "#".join(
            f"{episode_name(number, item['episodeCount'])}${media_url}"
            for number in range(1, item["episodeCount"] + 1)
        )
        result.update(
            {
                "vod_director": f"{item['director']} · {item['studio']}",
                "vod_actor": "、".join(item["cast"]),
                "vod_content": (
                    f"{item['synopsis']}\n\n"
                    "本条目及其人物、机构、图片和视频均为 OKVideoMac 文档演示所创作的虚构内容。"
                ),
                "vod_play_from": "原创风景演示$$$本地备用线路",
                "vod_play_url": f"{episodes}$$${episodes}",
            }
        )
    return result


class DemoHandler(BaseHTTPRequestHandler):
    server_version = "OKVideoMacDemo/0.4.0"

    @property
    def origin(self) -> str:
        host = self.headers.get("Host", f"127.0.0.1:{self.server.server_port}")
        return f"http://{host}"

    def log_message(self, format_string: str, *args: object) -> None:
        print(f"[demo] {self.address_string()} {format_string % args}")

    def do_HEAD(self) -> None:
        self.route(send_body=False)

    def do_GET(self) -> None:
        self.route(send_body=True)

    def route(self, send_body: bool) -> None:
        parsed = urlparse(self.path)
        if parsed.path in ("/", "/health"):
            self.send_json(
                {
                    "name": "OKVideoMac 0.4.0 Documentation Demo Source",
                    "status": "ok",
                    "catalogItems": len(ITEMS),
                    "liveChannels": len(CATALOG["liveChannels"]),
                    "config": f"{self.origin}/config.json",
                    "live": f"{self.origin}/live.m3u",
                },
                send_body,
            )
        elif parsed.path == "/config.json":
            self.send_json(
                {
                    "sites": [
                        {
                            "key": "okvideomac-docs-demo",
                            "name": "0.4.0 原创演示源",
                            "type": 1,
                            "api": f"{self.origin}/api",
                            "searchable": 1,
                            "quickSearch": 1,
                            "changeable": 1,
                            "timeout": 10,
                        }
                    ]
                },
                send_body,
            )
        elif parsed.path == "/api":
            self.serve_api(parse_qs(parsed.query), send_body)
        elif parsed.path == "/live.m3u":
            self.serve_live_playlist(send_body)
        elif parsed.path.startswith("/assets/posters/"):
            self.serve_asset(ASSETS / "posters", parsed.path.removeprefix("/assets/posters/"), send_body)
        elif parsed.path.startswith("/assets/art/"):
            self.serve_asset(ASSETS / "art", parsed.path.removeprefix("/assets/art/"), send_body)
        elif parsed.path.startswith("/assets/live/"):
            self.serve_asset(
                ASSETS / "live-banners",
                parsed.path.removeprefix("/assets/live/"),
                send_body,
            )
        elif parsed.path == "/media/demo-landscape.mp4":
            self.serve_file(ASSETS / "media" / "demo-landscape.mp4", send_body)
        else:
            self.send_error(HTTPStatus.NOT_FOUND, "Unknown demo endpoint")

    def serve_api(self, query: dict[str, list[str]], send_body: bool) -> None:
        detail_id = (query.get("ids") or [""])[0]
        if detail_id:
            item = next((candidate for candidate in ITEMS if candidate["id"] == detail_id), None)
            self.send_json({"list": [public_item(item, self.origin, True)] if item else []}, send_body)
            return

        keyword = (query.get("wd") or [""])[0].strip().casefold()
        category_id = (query.get("t") or [""])[0]
        try:
            page = max(1, int((query.get("pg") or ["1"])[0]))
        except ValueError:
            page = 1

        filtered = list(ITEMS)
        if keyword:
            filtered = [
                item
                for item in filtered
                if keyword
                in " ".join(
                    [
                        item["title"], item["alternateTitle"], item["synopsis"],
                        item["region"], *item["genres"]
                    ]
                ).casefold()
            ]
        if category_id:
            filtered = [item for item in filtered if item["category"] == category_id]

        filter_json = (query.get("f") or [""])[0]
        if filter_json:
            try:
                selected = json.loads(filter_json)
            except json.JSONDecodeError:
                selected = {}
            if selected.get("year"):
                filtered = [item for item in filtered if item["year"] == selected["year"]]
            if selected.get("region"):
                filtered = [item for item in filtered if item["region"] == selected["region"]]

        start = (page - 1) * PAGE_SIZE
        page_items = filtered[start : start + PAGE_SIZE]
        page_count = max(1, (len(filtered) + PAGE_SIZE - 1) // PAGE_SIZE)
        response = {
            "page": page,
            "pagecount": page_count,
            "limit": PAGE_SIZE,
            "total": len(filtered),
            "list": [public_item(item, self.origin) for item in page_items],
        }
        if not keyword and not category_id:
            response.update(
                {
                    "class": [
                        {"type_id": category["id"], "type_name": category["name"]}
                        for category in CATEGORIES
                    ],
                    "filters": {
                        category["id"]: [
                            {
                                "key": "year",
                                "name": "年份",
                                "value": [
                                    {"n": "全部", "v": ""},
                                    {"n": "2026", "v": "2026"},
                                    {"n": "2025", "v": "2025"},
                                    {"n": "2024", "v": "2024"},
                                ],
                            }
                        ]
                        for category in CATEGORIES
                    },
                }
            )
        self.send_json(response, send_body)

    def serve_live_playlist(self, send_body: bool) -> None:
        lines = ["#EXTM3U"]
        for channel in CATALOG["liveChannels"]:
            logo = f"{self.origin}/assets/live/channel-{channel['number']}.jpg"
            lines.append(
                "#EXTINF:-1 "
                f"tvg-id=\"demo-{channel['number']}\" "
                f"tvg-name=\"{channel['name']}\" "
                f"tvg-chno=\"{channel['number']}\" "
                f"tvg-logo=\"{logo}\" "
                f"group-title=\"{channel['group']}\",{channel['name']}"
            )
            lines.append(f"{self.origin}/media/demo-landscape.mp4")
        body = ("\n".join(lines) + "\n").encode("utf-8")
        self.send_bytes(body, "application/vnd.apple.mpegurl; charset=utf-8", send_body)

    def serve_asset(self, base: Path, raw_name: str, send_body: bool) -> None:
        name = Path(raw_name).name
        if name != raw_name or not re.fullmatch(r"[a-z0-9-]+\.(?:jpg|png)", name):
            self.send_error(HTTPStatus.BAD_REQUEST, "Invalid asset name")
            return
        self.serve_file(base / name, send_body)

    def serve_file(self, path: Path, send_body: bool) -> None:
        if not path.is_file():
            self.send_error(HTTPStatus.NOT_FOUND, "Demo asset not generated")
            return
        size = path.stat().st_size
        content_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        range_header = self.headers.get("Range")
        start, end = 0, size - 1
        status = HTTPStatus.OK
        if range_header:
            match = re.fullmatch(r"bytes=(\d*)-(\d*)", range_header.strip())
            if not match:
                self.send_error(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE)
                return
            first, last = match.groups()
            if first:
                start = int(first)
                end = min(int(last) if last else end, end)
            elif last:
                start = max(0, size - int(last))
            if start > end or start >= size:
                self.send_response(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE)
                self.send_header("Content-Range", f"bytes */{size}")
                self.end_headers()
                return
            status = HTTPStatus.PARTIAL_CONTENT

        length = end - start + 1
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(length))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Cache-Control", "public, max-age=3600")
        if status == HTTPStatus.PARTIAL_CONTENT:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if send_body:
            with path.open("rb") as handle:
                handle.seek(start)
                remaining = length
                while remaining:
                    chunk = handle.read(min(64 * 1024, remaining))
                    if not chunk:
                        break
                    try:
                        self.wfile.write(chunk)
                    except (BrokenPipeError, ConnectionResetError):
                        # mpv legitimately closes superseded Range requests while
                        # seeking or replacing a stream. Keep the local demo log
                        # quiet without masking real HTTP response failures.
                        break
                    remaining -= len(chunk)

    def send_json(self, value: object, send_body: bool) -> None:
        body = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_bytes(body, "application/json; charset=utf-8", send_body)

    def send_bytes(self, body: bytes, content_type: str, send_body: bool) -> None:
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if send_body:
            self.wfile.write(body)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1", help="Loopback host (default: 127.0.0.1)")
    parser.add_argument("--port", default=9480, type=int, help="Listen port (default: 9480)")
    args = parser.parse_args()
    if args.host not in {"127.0.0.1", "localhost", "::1"}:
        parser.error("The documentation demo may bind only to loopback")

    server = ThreadingHTTPServer((args.host, args.port), DemoHandler)
    print(f"OKVideoMac documentation demo: http://{args.host}:{args.port}/config.json")
    print(f"Live playlist: http://{args.host}:{args.port}/live.m3u")
    print("Press Control-C to stop.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
