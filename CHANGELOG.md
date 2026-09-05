# Changelog

## [0.4.0] - 2026-09-05

### Added

- Expanded selected TVBox/FongMi, QuickJS, CatPawOpen/Node, and Java/Dex
  compatibility while keeping Android Bridge optional.
- Added portable configuration and history backup and restore.
- Added structured cloud authorization handoff so playback can resume after a
  required account sign-in.

### Improved

- Search now isolates concurrent source sessions, preserves results when a
  running search is stopped, and gives Back, Escape, and Command-[ consistent
  navigation behavior.
- Detail loading and history replay retain the originating configuration,
  site, and request identity so late responses cannot replace newer content.
- Player lifecycle, buffering feedback, seeking, window restoration, and
  natural end-of-file auto-advance are more reliable.
- Cloud configuration uses native macOS sheets with system focus, dimming,
  keyboard, and accessibility behavior.
- Live and on-demand transitions, configuration switching, favorites, and
  history restoration have stronger stale-request isolation.

### Fixed

- Fixed missing or expired cloud credentials being shown as a generic player
  failure instead of opening the matching authorization flow.
- Fixed Quark reauthorization and Cookie rotation being mistaken for a new
  account, including safe discovery and reuse of existing transfer folders.
- Preserved exact transfer receipts so cleanup remains limited to the recorded
  saved file identifier and never scans or clears a whole cloud folder.
- Fixed structured authorization events being lost when the Node HTTP response
  and host-message channel completed at nearly the same time.
- Fixed search Back button visibility and reliability during rapidly updating
  aggregate searches.

### Security and release engineering

- Hardened runtime, nested-code signing, source/SBOM verification, sensitive
  information scanning, and Android Bridge version/signature contracts remain
  enforced by the Release package gate.
- The public artifact pipeline now produces a minimal Developer ID-signed DMG
  and binds it to the exact source release, SBOMs, notices, and checksums.

### Known limitations

- Apple Silicon (`arm64`) only; macOS 12 or later is required.
- Java/Dex compatibility requires an external Android SDK and emulator
  environment and remains experimental.
- Third-party Spider and cloud interfaces can change independently and may
  require future compatibility updates.
- TMDB metadata and detail enhancements are deferred to a future release.
- Large legacy database migrations can cause a one-time startup pause.

The current public release remains 0.3.41 until the 0.4.0 candidate is merged,
rebuilt from the exact `main` commit, notarized, stapled, verified, tagged, and
published.
