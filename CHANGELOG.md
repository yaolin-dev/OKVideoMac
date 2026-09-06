# Changelog

## [0.4.2] - 2026-09-06

### Fixed

- Replaced the Android Runtime's approximately 60-second ADB admission loop
  with a separate 180-second monotonic transport window; the existing Android
  guest boot wait begins only after the serial reaches `device`.
- Added a 20-second transient-offline grace period and one bounded, targeted
  reconnect whose result is retained independently in diagnostics.
- Isolated every OKVideoMac ADB operation and Emulator launch on a private,
  selected-SDK ADB server instead of sharing the global port 5037 daemon.
- Added one bounded host-to-software GPU fallback for an owned Emulator that
  stays offline for the complete transport window, and persist the backend
  that successfully reaches Runtime readiness.
- Added a recoverable private-AVD rebuild in Settings. It backs up only
  `OKVideoMac_Runtime` and never wipes userdata automatically or modifies other
  AVDs, Android Studio, global ADB, favorites, history, or normal settings.
- Build 97 adds the Emulator's official ADB-auth compatibility switch only for
  the private headless API 24–29 runtime, whose legacy boot-property path cannot
  provision a newly generated private host key. API 30+ authentication is
  unchanged.

### Diagnostics and safety

- Record private ADB server identity, transport summaries, Emulator/port
  liveness, reconnect evidence, GPU fallback, and startup/cleanup milestones.
- Record the selected guest ADB authentication mode, whether compatibility was
  actually enabled, and why it was selected without logging key material.
- Preserve the 0.4.1 process ownership, PID birth identity, single-flight,
  port-conflict, stale-lock, adoption, and owned-only shutdown guarantees.

### Validation scope

- The complete macOS suite passes 629 tests (625 passed, 4 intentionally
  skipped); Android Runtime tests cover delayed transport, ADB isolation,
  bounded fallback, repair isolation, and 10-way concurrent startup.
- The local API 35 private-ADB A/B reaches `device`, and Build 97 does not add
  the compatibility switch to API 30+. The user-specific API 24 / Emulator
  37.1.11 / M1 recovery result remains a real-machine validation item.

## [0.4.1] - 2026-09-06

### Fixed

- Fixed cases where an OKVideoMac-managed Android Runtime was mistaken for an
  unrelated Emulator after an App restart.
- Existing healthy or still-booting private runtimes are now adopted instead
  of launching a second instance of the same AVD.
- Concurrent Java/Dex requests now share one process-wide startup operation.
- Improved recovery when ADB is still starting, offline, or temporarily
  missing the expected Emulator transport.
- Normal App termination now closes the private Android Runtime, while a later
  launch can safely recover a runtime left by a crash or forced termination.

### Safety and release engineering

- Strengthened runtime ownership checks so Android Studio Emulators and other
  user AVDs are never targeted by OKVideoMac cleanup.
- Added PID-reuse protection and bounded, identity-verified shutdown fallback.
- Expanded Android Runtime lifecycle, adoption, shutdown, and concurrency
  regression coverage.
- Removed maintainer-machine paths from current public source and release
  tooling examples.

### Known limitations

- Apple Silicon (`arm64`) only; macOS 12 or later is required.
- Java/Dex compatibility remains Experimental and requires an external Android
  SDK, Emulator, and compatible arm64 system image.
- Third-party Spider and cloud interfaces can change independently.

## [0.4.0] - 2026-09-05

### Added

- Expanded selected TVBox/FongMi, QuickJS, CatPawOpen/Node, and Java/Dex
  compatibility while keeping Android Bridge optional and Experimental.
- Added portable configuration and history backup and restore.
- Added structured cloud authorization handoff so playback can resume after a
  required account sign-in.
- Added a native macOS window-sheet flow for configuration and authorization.
- Added deterministic Demo Source fixtures and original scenic media for
  privacy-safe documentation screenshots.

### Improved

- Search now isolates concurrent source sessions, preserves results when a
  running search is stopped, and gives Back, Escape, and Command-[ consistent
  navigation behavior.
- Detail loading and history replay retain the originating configuration,
  site, and request identity so late responses cannot replace newer content.
- Player lifecycle, buffering feedback, seeking, window restoration, and
  natural end-of-file auto-advance are more reliable.
- Long-series detail pages now paginate large episode sets and isolate stale
  detail responses during rapid navigation.
- Cloud configuration uses native macOS sheets with system focus, dimming,
  keyboard, and accessibility behavior.
- Live and on-demand transitions, configuration switching, favorites, and
  history restoration have stronger stale-request isolation.
- Live-TV grouping, channel switching, multi-line selection, and XMLTV EPG
  loading have clearer ownership and feedback.
- Toolbar placement, search progress, buttons, and page transitions use native
  macOS interaction semantics and honor Reduce Motion.

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
- Fixed repeated or late search/detail/playback callbacks reclaiming a newer
  page, configuration, site, or player request.
- Fixed selected player teardown, seek confirmation, EOF, reopening, and live
  channel-switching edge cases.
- Fixed history and favorite restoration losing the source configuration that
  originally produced an item.

### Security and release engineering

- Hardened runtime, nested-code signing, source/SBOM verification, sensitive
  information scanning, and Android Bridge version/signature contracts remain
  enforced by the Release package gate.
- The public artifact pipeline now produces a minimal Developer ID-signed DMG
  and binds it to the exact source release, SBOMs, notices, and checksums.
- The final 0.4.0 Build 94 DMG was accepted by Apple notarization, stapled, and
  passed Gatekeeper. The release set is bound to exact commit
  `f93d74fed86e3e2ffcfa4888c521a10f8e3e86f3` and tag `v0.4.0`.
- Four SPDX/CycloneDX SBOMs, required notices, the internal ZIP identity carrier,
  the public DMG, and corresponding source are included in the outer manifest.

### Known limitations

- Apple Silicon (`arm64`) only; macOS 12 or later is required.
- Java/Dex compatibility requires an external Android SDK and emulator
  environment and remains experimental.
- Third-party Spider and cloud interfaces can change independently and may
  require future compatibility updates.
- TMDB metadata and detail enhancements are deferred to a future release.
- Large legacy database migrations can cause a one-time startup pause.
