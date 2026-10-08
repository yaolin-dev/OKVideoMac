# Changelog

## [0.8.2] - 2026-10-08

- Release Build 135 repairs Android Runtime rebuild and recovery; formal publication requires the existing Apple distribution gates.
- Back up the private AVD compatibility fingerprint with the AVD, preventing stale system-image rejection after a rebuild.
- Record rebuild progress, restore matching original data after creation failure or interruption, and preserve failed new data for recovery.
- Freeze the selected system image during rebuild, preflight space on the AVD volume, and retain terminal failures in Settings.
- Keep existing SDK/image/ABI/emulator identity checks, private ADB keys, and other AVDs unchanged.


## [0.8.1] - 2026-10-08

- Fix previous/next navigation and autoplay when another episode in the same line has duplicate uploads; ambiguous adjacent uploads require a user choice.
- Add opt-in daily update checks, manual checking, playback-aware permission/reminders, and explicit download/install confirmation with Sparkle 2.10.0.
- Keep update installation and the ordinary relaunch helper mutually exclusive; installation waits for actual asynchronous cleanup.
- Fix CoreAudio Bluetooth device-change crashes using the #18383 backport and fault-tested failure cleanup.
- Release Build 134 for the stable HTTPS update feed; reject local/unconfigured update channels in distribution packages. Developer ID, Apple notarization, stapling and final artifact verification passed; see [formal verification](Docs/RELEASE_VALIDATION_0.8.1.md).

## [0.8.0] - 2026-10-01

Compared with published `v0.7.3` (Build 129). Release: **0.8.0 (Build 130)**.

### Added

- Selected Java/Dex TVBox configuration-card interactions with inline preparation,
  cancellation, owned native dialogs and Android configuration web pages. Web/form
  handoff is scoped to the current interaction and provider/JAR.
- Native playback authorization continuation: keep the original request through
  a delayed login window, then retry the same episode at most once after confirmation.
  Targeted login routes require the verified `[realm](auth)` configuration contract.
- Bounded, memory-only CatPaw search reuse (30-second TTL, 64 entries/5,000 items),
  identical active-search reuse, and recent-response-based ordering of Node attempts.

### Changed

- Search publishes the first results immediately and trailing batches on a 120 ms
  timer. All selected runnable providers still attempt page one; global and shared
  Node concurrency remain 20. Partial-result status explains unfinished providers.
- Separate Node cache revisions from configuration semantics and authorization
  identity. Cache writes invalidate reusable data without cancelling page-owned
  details; genuine provider changes preserve the route and allow retry.
- Adapt player title, volume, time and tools to window width. Full-screen video,
  subtitle and danmaku transforms no longer scale the sibling controls and panels.
- Use current-request mpv seek/restart events for seek readiness, accepting valid
  keyframe landing differences and rejecting events from an older seek.
- Android Dex Bridge: **0.3.45 (57) → 0.3.48 (60)**. App build: **129 → 130**.

### Fixed

- Configuration actions no longer wait indefinitely for a nonexistent window,
  refresh a departed category, replay a completed action, or steal a newer request.
  Ambiguous configuration/auth protocols and plain Cookie error text are not guessed.
- Prevent Node profile cache writes from replacing a provider or interrupting detail
  loading; account/configuration/endpoint changes still invalidate relevant caches.
- Fix clipped progress timestamps/tooltips and stale hover after dragging, focus,
  resize, media changes and full-screen transitions.
- Infer unambiguous numbered video-file sequences across different prefixes,
  descending lists and gaps in established sequences, grouped by season/version.
  Exclude non-main/audio/subtitle resources and avoid arbitrary duplicate-number
  selection; list inference does not create trusted persistent resource identities.
- Wait for history episode-list restoration before automatic continuation, show
  incomplete queue state, reload media on replay, and honor autoplay at a confirmed
  user-seek boundary while keeping premature EOF excluded.
- Recover an owned emulator after private ADB binding changes without launching a
  second copy of its AVD. Failed port probes no longer mean a port is free; diagnostic
  export uses recorded observations without starting ADB. Includes commit `5780acd`.

### Compatibility and release

- Apple Silicon / arm64 and macOS 12.0+ remain required. Java/Dex remains Experimental;
  configuration, authorization, Node and filename inference support bounded subsets.
- Full Guide, danmaku, source-aware History/Favorites and backup schema v4 were already
  published in 0.7.3. No new backup schema or native/Maven dependency upgrade is included.
- Formal 0.8.0 passed Developer ID signing, Apple notarization, stapling, Gatekeeper
  and fresh-installation smoke. Tag `v0.8.0` pins `b049b381db52b5bbbeec9cf58bf54a5bd50a4f39`;
  15 public assets include the DMG and corresponding source/SBOM/checksum material.
  See [release notes](Docs/RELEASE_NOTES_0.8.0.md),
  [validation](Docs/RELEASE_VALIDATION_0.8.0.md) and
  [file/commit preparation](Docs/RELEASE_PREPARATION_0.8.0.md).

## [0.7.3] - 2026-09-27

### Added

- Added a bounded native Full Guide for XMLTV and Native Xtream live sources. It
  uses virtualized rows, fixed time geometry, date navigation, Now repositioning,
  current-programme progress and independent channel/time-axis clipping.
- Added native danmaku playback for supported TVBox/CatPaw-style and Xtream
  sessions, including Bilibili XML import, XML/JSON payload parsing, source-provided
  services, automatic episode matching, explicit candidate selection and timing
  calibration.
- Added source-aware native History and Favorites lists. Portable backup schema v4
  carries stable favorite and danmaku identities without exporting runtime URLs,
  request headers, cookies, proxy leases or account credentials.

### Changed

- Reworked browsing, search, detail and long-series navigation around explicit
  request ownership, resumable pagination, bounded caches and source-preserving
  route state. Native lists and poster grids now share consistent hover, selection,
  keyboard and scrolling behavior.
- Refined the live and Guide interface with native date controls, programme detail,
  predictable source/group/channel restoration, row progress and content-only
  separators.
- Unified media identity, season/episode naming and continuation rules across
  details, history and playback. Volume and mute preferences are shared between VOD
  and live playback and restored before a new player becomes audible.
- Native Xtream VOD and live requests now honor the current system HTTP/HTTPS proxy
  within the media session. Short EPG is supported; catch-up/timeshift and
  `direct_source` remain outside the supported subset.
- Android Dex Bridge is now 0.3.45 (57), with provider lifecycle/epoch isolation and
  verified Dex/JAR caching. Quark authorization and transfer state use stricter
  request ownership and media-failure classification.

### Fixed

- Fixed stale detail/search/category responses, cancelled pagination work and late
  provider callbacks replacing a newer page or playback request.
- Fixed history resume selecting a resource by list position, stale cached episode
  metadata or an ambiguous movie/series match. Deleting or completing an entry is
  transactional and cannot be recreated by a late write from the same session.
- Fixed live logo reuse crashes, source restoration, full-screen aspect handling and
  cases where video/audio continued but the window could not leave full screen.
- Fixed danmaku animation jitter by driving motion from the display refresh,
  smoothing the player clock and caching rendered text bitmaps. Pause, buffering,
  seek and episode changes now have separate synchronization paths.
- Restored separators only between populated History and Favorites rows, while
  keeping empty-list regions free of grid lines.

### Compatibility and release

- Apple Silicon (`arm64`) and macOS 12.0 or later remain required.
- The Developer ID signed 0.7.3 distribution passed Apple notarization, stapling,
  Gatekeeper and final DMG installation smoke. Tag `v0.7.3` pins exact release
  commit `55ffa9d55faced404b20034d7cfe5bcfbc1be581`.
- See `Docs/RELEASE_NOTES_0.7.3.md` and `Docs/RELEASE_VALIDATION_0.7.3.md` for the
  final validation results, artifact hashes and known limitations.

## [0.6.1] - 2026-09-09

### Added

- Categorized Android Compatibility storage reporting for managed components,
  installation cache, user data and backups.
- Safe uninstall of recognized Android components managed by OKVideoMac, with
  estimated reclaimed space and later component reinstallation.

### Safety / Changed

- Preserve Android AVD/user data and login state, backing/encryption files, Android
  home, private ADB keys, user-data backups and runtime selection during component uninstall.
  External SDKs are excluded; Android user-data deletion is not offered.
- Require the OKVideoMac Android session to stop before uninstall, including External
  mode. Revalidate short-lived, single-use plans and use a separate Maintenance
  transaction for interrupted-operation recovery and pending cleanup.
- Preserve AVD backups when repair rollback cannot restore their contents; explicit
  External mode does not inherit a coexisting Managed generation's AVD context.

### Documentation

- Synchronize English and Simplified Chinese README facts and release metadata.
- Give existing Native Xtream support first-screen, provider-table and compatibility
  visibility. Xtream was introduced in 0.6.0 and is not a new feature in this patch.
- Document managed component storage, uninstall boundaries and retained user data.

See [0.6.1 release notes](Docs/RELEASE_NOTES_0.6.1.md). Apple Silicon / arm64,
macOS 12.0+. The Developer ID signed DMG passed Apple notarization (`Accepted`),
stapling, Gatekeeper and installation smoke tests; see the
[validation record](Docs/RELEASE_VALIDATION_0.6.1.md).

## [0.6.0] - 2026-09-09

### Added

- Native Xtream-compatible account authentication, Movies, Series, season/episode
  navigation, combined catalog search and Basic Live. Credentials stay in Keychain;
  persisted playback references and exports exclude account secrets.
- English and Simplified Chinese String Catalog UI, persistent language selection
  and restart/relaunch support.

### Playback and fixes

- Isolated Native Live static HTTP proxy/HTTPS CONNECT handling, normal 302 media
  redirects, bounded 60-second startup and conservative backup-HLS master selection
  preserving audio/subtitles. Existing imported Live and VOD startup policies remain.
- Request ownership and player-instance boundaries protect cancellation, switching
  and closing from stale events and transport-state contamination.
- Empty VOD metadata arrays now use existing catalog details; malformed metadata
  remains rejected.
- Grouped source configuration, content-sized player utility panels across window
  sizes, and reliable browser back-button hit targets and route updates.

- Android shutdown normalizes system directory aliases on both sides of its
  private-AVD check while retaining strict process ownership boundaries.

### Compatibility

- Existing TVBox/CatVod, CatPaw-style Node, QuickJS, Android csp_, direct/local media
  and imported Live retain their documented scope.
- Native Xtream EPG, catch-up/timeshift and direct_source were unsupported in 0.6.0; proxy
  and HLS support is deliberately bounded, not universal.
- Apple Silicon / arm64, macOS 12.0+. See Docs/RELEASE_NOTES_0.6.0.md for details.

## [0.5.0] - 2026-09-07

### Managed Android Runtime

- Added explicit **Managed Runtime** and **External SDK** modes. Managed remains
  the recommended default; existing and advanced users can explicitly retain a
  compatible Android SDK without being forced through a Managed download.
- Added versioned, atomic `runtime-selection.json` persistence and one-time
  migration of the historical SDK preference. Ambient `PATH`, `ANDROID_HOME`,
  Homebrew, and Android Studio discovery never silently change the selected
  mode.
- Added an on-demand Android compatibility component installer inside
  OKVideoMac. The first actual Java/Dex request is suspended while the user
  reviews licenses and installs; success resumes that same request.
- Added a production, immutable API 35 Google APIs arm64 profile with pinned
  Google Android artifacts and Azul Zulu JRE 17, exact sizes, SHA-256 hashes,
  license links, host allowlisting, and archive-layout limits.
- Added resumable downloads, truthful byte progress, disk preflight, staging,
  structure/version validation, immutable Runtime Generations, and atomic
  `current-runtime.json` activation. Failure and cancellation preserve the
  active Runtime and the separate AVD userdata.
- Added an installation single-flight independent of the existing Emulator
  startup single-flight. Concurrent Settings and Dex requests join one
  installation, then pass the Managed Environment Purity gate before Session.
- Added Settings install/update/repair states, explicit External SDK
  selection/confirmation, and path-free diagnostic output. External validation
  separates existing-AVD launch capability from Java/`avdmanager`-dependent
  create/repair capability.
- Added a strict compatibility fingerprint for the shared private AVD. Runtime
  source/identity, API, ABI, system image, schema, and Emulator compatibility
  mismatches fail closed without silently deleting or rebuilding userdata.
- API 35 remains an `evaluation` candidate and the shipped default managed
  profile. Real Emulator E2E is verified only on M1 / macOS 14.8.8; other
  supported macOS versions are not represented as field-verified.

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
- Includes the Emulator's official ADB-auth compatibility switch only for
  the private headless API 24–29 runtime, whose legacy boot-property path cannot
  provision a newly generated private host key. API 30+ authentication is
  unchanged.
- Replaced the custom primary sidebar with an AppKit source list on the native
  sidebar material, including semantic blue symbols, neutral selection, native
  search control sizing, and active/inactive window appearance.
- Matched App Store search cancellation: Escape first clears a non-empty query
  without dropping focus; a second Escape on the empty field exits search.

### Diagnostics and safety

- Record private ADB server identity, transport summaries, Emulator/port
  liveness, reconnect evidence, GPU fallback, and startup/cleanup milestones.
- Record the selected guest ADB authentication mode, whether compatibility was
  actually enabled, and why it was selected without logging key material.
- Preserve the 0.4.1 process ownership, PID birth identity, single-flight,
  port-conflict, stale-lock, adoption, and owned-only shutdown guarantees.
- Managed mode never invokes External Android tools; External mode never enters
  Managed installation admission. Switching modes requires a stopped Session.

### Quit and lifecycle

- Visible windows now leave the screen immediately after a confirmed App Quit,
  while required Player, history, Node, and owned Android Runtime cleanup
  continues in the background before AppKit completes process termination.
- Preserved the full healthy `adb emu kill` grace period. Only later fallback
  polling and escalation are shortened; `SIGTERM` and `SIGKILL` remain bounded
  last-resort paths after strict ownership validation.
- Repeated Quit requests share one termination operation. Cleanup remains
  limited to OKVideoMac-owned Emulator and private ADB processes and never
  targets unrelated Android Studio or user AVDs.

### Validation scope

- The complete macOS suite passes 649 tests (643 passed, 6 intentionally
  skipped); Android Runtime tests cover delayed transport, ADB isolation,
  bounded fallback, repair isolation, and 10-way concurrent startup.
- The local API 35 private-ADB A/B reaches `device`, and this release does not add
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
