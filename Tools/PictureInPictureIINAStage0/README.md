# IINA-style native PiP experiment

This is an isolated feasibility experiment, not a shipped application feature.
It moves one existing `NSOpenGLView`, CGL context and libmpv client into the
system `PIPViewController`, then restores the same view to its original host.
It does not capture the screen, re-encode playback, reload the media on entry,
or bundle Apple's private framework.

## Gate status — 2026-10-15

On macOS 14.8.9 arm64, all seven required selector argument signatures match.
Simulated framework absence disables entry safely. The optional
`updatePlaybackStateUsingBlock:` method is absent, so native timeline controls
must not be assumed on this OS.

The user confirmed that the actual system PiP panel shows the purple background,
moving green block and mpv fixture text. Runtime evidence also recorded native
play/pause callbacks, return without reloading, and paused entry/return at the same
position, using one player and one render context.

A CoreAudio start failure occurred during the initial run. A standalone Apple
AudioToolbox probe failed at that time as well, but this did not establish a
system-wide failure: the user confirmed other apps had normal audio. On recheck,
the probe started successfully, and Run 8 used real CoreAudio output and
VideoToolbox hardware decoding with advancing audio/video timestamps and the
same context across PiP round trips. The retained current source uses those real
outputs. Run 7 used a null audio clock and software decoding solely to separate
the rendering gate; it is not evidence of audible audio.

Production integration and its focused Release regression now live in the app
source. See `OKVideoMac/macOS/OKVideoMac/Docs/PICTURE_IN_PICTURE.md` for behavior,
implementation and remaining platform limitations. No GitHub update, publication
or Desktop App installation is part of this work.

## Reproduce

`Source/build.py` requires a fresh output directory, a previously verified local
Release app as read-only native-library input, and its matching `OKMPVBridge.h`.
It creates a synthetic H.264/PCM fixture, builds an optimized isolated application,
records input/source hashes, checks its local signature and checks that the private
framework is not statically linked. Launch the output through the UI and use its
buttons or Command-P / Command-R. Command-Q quits this experiment only.

`Source/verify_evidence.py <output>/Evidence/runtime.json` checks a completed
playing round trip followed by a paused round trip and another playing entry.
The verifier deliberately leaves visual, native-control and sound gates pending.
Runtime logs and generated media stay outside version control.

## Compatibility and sources

The private selector declarations were checked against IINA's published
[bridging header](https://github.com/iina/iina/blob/develop/iina/iina-Bridging-Header.h)
and the view-transfer approach against IINA commit
`e6bb8fdfc995e96b1d74b767c98c8826f597d4b7`. Experiment code is original.
Private APIs may change between OS versions; checking selectors alone is not a
compatibility guarantee. App Store review guideline 2.5.1 requires public APIs,
so this path is unsuitable for a Mac App Store build. Local signing does not
establish notarization or future OS compatibility.
