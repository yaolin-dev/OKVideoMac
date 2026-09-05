#!/usr/bin/env python3
"""Remove the capture pointer and metadata from the final 0.4.0 screenshots.

Computer Use captures the real Release windows but includes the macOS pointer.
For documentation we replace only the small pointer rectangle with pixels from
the same adjacent native surface. No application UI, text or state is changed.
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parent

# file: (left, top, right, bottom)
# Each rectangle sits on a surface whose horizontal styling is continuous:
# titlebar, search field, blank detail canvas or selected sidebar row.
CLEANUPS = {
    "search.png": (84, 45, 164, 111),
    "series-detail.png": (1090, 210, 1180, 305),
    "live-channels.png": (90, 132, 180, 205),
    "settings.png": (90, 260, 180, 330),
}


def horizontal_fill(image: Image.Image, rect: tuple[int, int, int, int]) -> Image.Image:
    image = image.convert("RGB")
    pixels = image.load()
    left, top, right, bottom = rect
    span = right - left
    for y in range(top, bottom):
        start = pixels[left - 1, y]
        end = pixels[right, y]
        for offset, x in enumerate(range(left, right), start=1):
            amount = offset / (span + 1)
            pixels[x, y] = tuple(
                round(start[channel] * (1 - amount) + end[channel] * amount)
                for channel in range(3)
            )
    return image


def main() -> None:
    for filename, rect in CLEANUPS.items():
        path = ROOT / filename
        image = Image.open(path).convert("RGB")
        image = horizontal_fill(image, rect)
        image.save(path, format="PNG", optimize=True)
        print(f"sanitized {filename}")

    # The live-player pointer sat over a smooth, purely generated blue region.
    # It was removed once with a harmonic interpolation of the surrounding
    # pixels before this checked-in helper was added. Re-running this script is
    # intentionally a no-op for that already clean frame.
    for filename in ("vod-playback.png", "live-playback.png"):
        path = ROOT / filename
        image = Image.open(path).convert("RGB")
        image.save(path, format="PNG", optimize=True)
        print(f"stripped metadata from {filename}")


if __name__ == "__main__":
    main()
