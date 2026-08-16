# OKVideoMac App Icon Provenance

Status: **FINAL RELEASE IDENTITY VERIFIED; FINAL ARTWORK SOURCE PROVENANCE IS
NOT ESTABLISHED BY THE RETAINED IMAGEGEN FILES**

Date created: 2026-08-13
Provenance boundary corrected: 2026-08-16

## Final v0.3.41 runtime icon

OKVideoMac v0.3.41 Build 64 ships the red/coral icon with a white rounded
aperture and play mark. Its source identity is the ten PNG files in:

```text
OKVideoMac/macOS/OKVideoMac/Resources/Assets.xcassets/AppIcon.appiconset/
```

Commit `ae7fa3d20c2feb46f53758f946d7b18cd239b76a` replaced those ten catalog
PNGs and established the final runtime artwork. The same files are present in
the v0.3.41 Build 63 pre-publication candidate commit at
`b0b6fec221325dde0a20d742949a95548cf0e5e7` and remain unchanged on the Build 64
mainline. Xcode selects the `AppIcon`
catalog and compiles it into `AppIcon.icns` and `Assets.car` for the Build 64
application bundle.

This confirms which artwork the release builds and ships. It does not, by
itself, establish the creative or source-file provenance of the final red
artwork.

## Historical ImageGen source

The following retained files document an earlier, intermediate icon-generation
stage introduced in commit `8e05a3d344903295ff66de6cde52ca4ed7158b44`:

```text
OKVideoMac/Assets/AppIcon/OKVideoMac-AppIcon-ImageGen-source.png
OKVideoMac/Assets/AppIcon/OKVideoMac-AppIcon-master-1024.png
```

They depict a deep-indigo tile with a teal/cyan ribbon and play motif. At the
`8e05a3d` state, the AppIcon catalog PNGs were size reductions of the retained
1024-pixel master. The original generation was created specifically for
OKVideoMac without an input image or third-party asset; its brief expressly
excluded Apple, FongMi, TVBox, YouTube, Netflix, VLC, QuickTime, other
third-party marks, and copyrighted film imagery.

These files are retained for historical traceability. They are not referenced
by `AppIcon.appiconset/Contents.json`, the Xcode AppIcon selection, an icon
generation script, packaging, or release scripts. They are not runtime assets
and are not the final v0.3.41 icon.

For this historical generated output, the project retains the no-input
generation record and has no identified stock image, font, logo, or external
design-file dependency. This is not a jurisdiction-specific legal opinion
about copyrightability of AI-assisted works.

## Historical generation record

- Tool: Codex built-in `image_gen` tool (`imagegen` skill workflow).
- Input images: none.
- Generated source SHA-256:
  `147b37b7eada29efb420b5b78836d9d8c695cb9d17e1718f12fc39551063c835`.
- 1024px master SHA-256:
  `1b795d144d5d0244b109e97380d91af7dc48965e0a8eb3993c85968dd6becd3d`.
- Post-processing: selection of the single generated result and proportional
  resizing with macOS `sips`; no compositing or external material.

## Historical generation prompt

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

## Timeline and provenance boundary

- `8e05a3d`: added the blue ImageGen output and 1024-pixel master, and
  generated the intermediate AppIcon catalog from that master.
- `ae7fa3d`: replaced only the ten AppIcon catalog PNGs with the final red
  runtime artwork; the blue source and master were retained unchanged.
- `b0dc0e8`: advanced the application build number from 62 to 63.
- `b0b6fec`: finalized the v0.3.41 Build 63 release state with the red AppIcon
  catalog.

Repository evidence confirms the identity and release path of the final red
runtime icon. It does not establish the retained blue ImageGen output or master
as the direct source of that red artwork, and no such derivation should be
inferred from the retained historical files.
