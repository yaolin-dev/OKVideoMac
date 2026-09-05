#!/usr/bin/env python3
"""Build deterministic posters and landscape video frames for the docs-only demo.

The six checked-in base artworks are original images generated for this project.
This script performs only local crops, color treatment and typography. It does
not download or reference third-party media.
"""

from __future__ import annotations

import json
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageEnhance, ImageFilter, ImageFont, ImageOps


ROOT = Path(__file__).resolve().parent
CATALOG = ROOT / "catalog.json"
ART = ROOT / "assets" / "art"
POSTERS = ROOT / "assets" / "posters"
LIVE_BANNERS = ROOT / "assets" / "live-banners"
FRAMES = ROOT / "assets" / "video-frames"

FONT_CANDIDATES = (
    Path("/System/Library/Fonts/PingFang.ttc"),
    Path("/System/Library/Fonts/STHeiti Medium.ttc"),
    Path("/System/Library/Fonts/Supplemental/Arial Unicode.ttf"),
)

ACCENTS = (
    (91, 103, 220),
    (29, 170, 170),
    (241, 116, 91),
    (226, 176, 60),
    (91, 156, 226),
    (171, 104, 219),
)


def font(size: int, index: int = 0) -> ImageFont.FreeTypeFont:
    for candidate in FONT_CANDIDATES:
        if candidate.exists():
            try:
                return ImageFont.truetype(str(candidate), size=size, index=index)
            except OSError:
                continue
    return ImageFont.load_default()


def multiline_title(title: str) -> str:
    if len(title) <= 5:
        return title
    midpoint = math.ceil(len(title) / 2)
    return f"{title[:midpoint]}\n{title[midpoint:]}"


def gradient_overlay(size: tuple[int, int], start_y: int) -> Image.Image:
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    height = size[1] - start_y
    for offset in range(max(height, 1)):
        alpha = int(225 * (offset / max(height - 1, 1)) ** 1.5)
        draw.line((0, start_y + offset, size[0], start_y + offset), fill=(8, 12, 28, alpha))
    return layer


def make_poster(item: dict, index: int) -> None:
    width, height = 600, 900
    source = Image.open(ART / f"{item['art']}.jpg").convert("RGB")

    # Each repeated base illustration receives a deterministic crop, tint and
    # contrast treatment so the catalog reads as a coherent family, not clones.
    focus_x = 0.42 + ((index % 3) - 1) * 0.07
    focus_y = 0.48 + (((index // 3) % 3) - 1) * 0.05
    poster = ImageOps.fit(source, (width, height), method=Image.Resampling.LANCZOS,
                          centering=(focus_x, focus_y))
    poster = ImageEnhance.Color(poster).enhance(0.90 + (index % 4) * 0.07)
    poster = ImageEnhance.Contrast(poster).enhance(1.02 + (index % 3) * 0.05)

    accent = ACCENTS[index % len(ACCENTS)]
    tint = Image.new("RGB", (width, height), accent)
    poster = Image.blend(poster, tint, 0.035 + (index % 2) * 0.02).convert("RGBA")
    poster = Image.alpha_composite(poster, gradient_overlay((width, height), 485))

    draw = ImageDraw.Draw(poster)
    small = font(23)
    title_font = font(57, index=1)
    alt_font = font(22)
    meta_font = font(20)

    pill = (42, 54, 192, 94)
    draw.rounded_rectangle(pill, radius=20, fill=(*accent, 230))
    draw.text((62, 63), "OK DEMO", font=small, fill=(255, 255, 255, 255))

    title = multiline_title(item["title"])
    draw.multiline_text((42, 616), title, font=title_font, fill=(255, 255, 255, 255),
                        spacing=4, stroke_width=1, stroke_fill=(0, 0, 0, 110))
    draw.text((45, 760), item["alternateTitle"].upper(), font=alt_font,
              fill=(224, 229, 245, 235))
    meta = f"{item['year']}  ·  {' / '.join(item['genres'][:2])}  ·  {item['rating']}"
    draw.text((45, 812), meta, font=meta_font, fill=(243, 244, 250, 235))
    draw.rounded_rectangle((42, 856, 558, 862), radius=3, fill=(*accent, 235))

    POSTERS.mkdir(parents=True, exist_ok=True)
    poster.convert("RGB").save(
        POSTERS / f"{item['id']}.jpg",
        format="JPEG",
        quality=88,
        optimize=True,
        progressive=True,
    )


def make_live_banner(channel: dict, index: int) -> None:
    width, height = 960, 540
    source = Image.open(ART / f"{channel['art']}.jpg").convert("RGB")
    focus_x = 0.42 + (index % 3) * 0.07
    banner = ImageOps.fit(
        source,
        (width, height),
        method=Image.Resampling.LANCZOS,
        centering=(focus_x, 0.48),
    ).convert("RGBA")

    # A restrained native-TV style lower gradient keeps each 16:9 banner
    # readable at card size without pretending to be a real broadcaster mark.
    banner = Image.alpha_composite(banner, gradient_overlay((width, height), 250))
    draw = ImageDraw.Draw(banner)
    accent = ACCENTS[index % len(ACCENTS)]
    label_font = font(27)
    name_font = font(54, index=1)
    number_font = font(24)
    draw.rounded_rectangle((48, 44, 204, 87), radius=22, fill=(*accent, 235))
    draw.text((70, 51), f"{channel['group']} · DEMO", font=number_font, fill="white")
    draw.text((48, 390), channel["name"], font=name_font, fill="white",
              stroke_width=1, stroke_fill=(0, 0, 0, 100))
    draw.text((51, 466), f"CH {channel['number']}  ·  ORIGINAL LANDSCAPE",
              font=label_font, fill=(231, 236, 248, 240))
    draw.rounded_rectangle((48, 509, 912, 516), radius=4, fill=(*accent, 235))

    LIVE_BANNERS.mkdir(parents=True, exist_ok=True)
    banner.convert("RGB").save(
        LIVE_BANNERS / f"channel-{channel['number']}.jpg",
        format="JPEG",
        quality=88,
        optimize=True,
        progressive=True,
    )


def make_landscape_frame(art_name: str, frame_number: int, total: int) -> None:
    width, height = 1280, 720
    source = Image.open(ART / f"{art_name}.jpg").convert("RGB")
    progress = frame_number / max(total - 1, 1)

    # Gentle Ken Burns motion: only scale/crop operations, designed to remain
    # visually useful even when Reduce Motion is enabled in the host app.
    scale = 1.06 + 0.08 * progress
    target = (int(width * scale), int(height * scale))
    fitted = ImageOps.fit(source, target, method=Image.Resampling.LANCZOS,
                          centering=(0.50, 0.48))
    max_x = fitted.width - width
    max_y = fitted.height - height
    left = int(max_x * (0.12 + 0.70 * progress))
    top = int(max_y * (0.28 + 0.18 * math.sin(progress * math.pi)))
    frame = fitted.crop((left, top, left + width, top + height))
    frame = ImageEnhance.Color(frame).enhance(1.06)
    frame = ImageEnhance.Contrast(frame).enhance(1.04)

    # Subtle vignette keeps player controls readable without painting UI into
    # the media itself.
    vignette = Image.new("L", (width, height), 0)
    vdraw = ImageDraw.Draw(vignette)
    for inset in range(0, 180, 3):
        alpha = max(0, 80 - int(inset * 0.42))
        vdraw.rounded_rectangle((inset, inset // 2, width - inset, height - inset // 2),
                                radius=90, outline=alpha, width=4)
    shadow = Image.new("RGB", (width, height), (8, 12, 25))
    frame = Image.composite(shadow, frame, vignette.filter(ImageFilter.GaussianBlur(35)))

    FRAMES.mkdir(parents=True, exist_ok=True)
    frame.save(FRAMES / f"frame-{frame_number:04d}.jpg", quality=89, optimize=True)


def main() -> None:
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    for index, item in enumerate(catalog["items"]):
        make_poster(item, index)
    for index, channel in enumerate(catalog["liveChannels"]):
        make_live_banner(channel, index)

    # Four bright, purely scenic sequences become a 16-second local demo video.
    frame_count = 192
    segment_names = ("ocean", "vessel", "orbit", "city")
    for frame_number in range(frame_count):
        segment = min(frame_number // 48, len(segment_names) - 1)
        make_landscape_frame(segment_names[segment], frame_number, frame_count)

    print(
        f"Generated {len(catalog['items'])} posters, "
        f"{len(catalog['liveChannels'])} live banners and {frame_count} landscape frames"
    )


if __name__ == "__main__":
    main()
