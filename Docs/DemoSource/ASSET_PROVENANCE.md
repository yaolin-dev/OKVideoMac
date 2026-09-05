# Demo asset provenance

All files below were made for OKVideoMac documentation on 2026-09-05 and may
be redistributed with this repository under the repository's license. They are
not sourced from a film, television service, broadcaster, stock-media library
or third-party catalog.

## Original base artwork

The six source images in `assets/art/` were generated from original prompts
with OpenAI's built-in image-generation tool. The prompts requested abstract or
fictional scenic compositions and expressly excluded people, text, logos,
watermarks, brands, real landmarks and recognizable intellectual property:

- `orbit.jpg`: fictional orbital observatory above a blue planet.
- `city.jpg`: fictional near-future city in rain at blue hour.
- `ocean.jpg`: luminous ocean trench and open horizon.
- `archive.jpg`: abstract translucent archive and coral doorway.
- `vessel.jpg`: fictional electric vessel in misty mountains.
- `workshop.jpg`: tactile geometric paper-and-glass workshop.

## Derived assets

- `assets/posters/*.jpg` are local crops, color treatments and typography
  produced by `generate_assets.py` from the six original base images.
- `assets/live-banners/*.jpg` are dedicated 16:9 channel identities made from
  the same original scenery; no real broadcaster name or logo is used.
- `assets/media/demo-landscape.mp4` is a silent 1280×720 H.264 sequence made by
  `generate_assets.py` and `make_demo_video.swift` from the same original
  scenery. The 16-second scenic sequence repeats eight times in the 128-second
  file so both VOD and live-player screenshots can be captured reliably. It is
  used for both player documentation screenshots.
- Titles, alternate titles, production credits, channel names and descriptions
  come from the hand-authored fictional `catalog.json` fixture.

The resulting assets are documentation fixtures. They are not product defaults
and do not imply that OKVideoMac supplies a content catalog.
