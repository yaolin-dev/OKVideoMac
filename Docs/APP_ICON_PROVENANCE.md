# OKVideoMac App Icon Provenance

Status: **VERIFIED OWNED** for OKVideoMac release provenance

Date created: 2026-08-13

## Rights and source statement

The Phase 2 icon was created specifically for OKVideoMac without any input
image or third-party asset. It replaces the earlier icon whose authorship and
license could not be proven. The generation brief expressly excluded Apple,
FongMi, TVBox, YouTube, Netflix, VLC, QuickTime, other third-party marks, and
copyrighted film imagery.

The project retains the original generation output and the 1024-pixel release
master under `OKVideoMac/Assets/AppIcon/`. The asset catalog PNGs are
deterministic size reductions of that master. No stock image, font, logo, or
external design file is incorporated.

`VERIFIED OWNED` here means the project controls the generated output and its
release provenance and has no identified third-party asset dependency. It is
not a jurisdiction-specific legal opinion about copyrightability of
AI-assisted works.

## Generation record

- Tool: Codex built-in `image_gen` tool (`imagegen` skill workflow).
- Input images: none.
- Generated source SHA-256:
  `147b37b7eada29efb420b5b78836d9d8c695cb9d17e1718f12fc39551063c835`.
- 1024px master SHA-256:
  `1b795d144d5d0244b109e97380d91af7dc48965e0a8eb3993c85968dd6becd3d`.
- Post-processing: selection of the single generated result and proportional
  resizing with macOS `sips`; no compositing or external material.

## Prompt

```text
Use case: logo-brand
Asset type: official macOS application icon master artwork for the open-source OKVideoMac video player
Primary request: create an original, polished macOS app icon that communicates an open, calm video viewing experience without resembling any existing TV-box or streaming-service logo
Subject: an abstract circular aperture made from two flowing ribbon arcs, with a small negative-space play wedge at the center; no television outline, no antenna, no letters
Style/medium: premium modern 3D vector-like icon, clean geometry, subtle depth, crisp at small sizes, macOS Dock quality
Composition/framing: centered symbol on a rounded-square tile, generous safe padding, perfectly square 1024x1024 composition
Lighting/mood: soft studio lighting, confident and calm
Color palette: deep midnight indigo background, original teal-to-cyan ribbon with a restrained warm amber highlight; avoid red/pink dominant palettes
Materials/textures: soft satin/glass hybrid with restrained highlights, no photorealism
Constraints: entirely original composition; no Apple trademarks; no FongMi, TVBox, YouTube, Netflix, VLC, QuickTime, or other third-party marks; no copyrighted film imagery; no text; no watermark; no TV frame; no antenna; no external shadow outside the square canvas; keep important artwork inside macOS icon safe margins
Avoid: generic red play button, copied brand silhouettes, excessive detail, tiny decorative elements, transparent canvas
```

## Asset mapping

The files in `macOS/OKVideoMac/Resources/Assets.xcassets/AppIcon.appiconset/`
are generated at 16, 32, 64, 128, 256, 512, and 1024 pixels from the retained
1024px master. Duplicate logical sizes used by different macOS scale slots are
expected to have identical hashes.
