# Automatic updates

## Published 0.8.3 update

The stable latest feed offers 0.8.3 (136), using the existing HTTPS URL and public key. The final signed appcast/DMG match, and all 16 anonymous public downloads have matching SHA-256. Stable 0.8.1/0.8.2 feed/key/version compatibility is retained. This does not claim a new native old-App UI run, a complete 24-hour schedule or end-to-end update installation.

Local previews without feed/key correctly disable Check for Updates. The formal App embeds `StableUpdateConfiguration.plist` and passes `verify_update_bundle.py --require-stable`. See [formal verification](RELEASE_VALIDATION_0.8.3.md). The earlier published observations below remain historical.

Sparkle is pinned to the official 2.10.0 distribution and source commit in
`ThirdParty/sparkle-lock.json`. `Scripts/prepare-sparkle.py` checks the archive
SHA-256 before extracting it, verifies its five executable paths, thins those
executables to arm64, and records provenance. The application does not contain
Sparkle's command-line signing tools or an update private key.

## User behavior

The application starts the updater only after startup, while active, with no
player, full-screen or modal window. A wrapper delays Sparkle's native consent
request if playback begins before it is shown. The user's decision is stored by
Sparkle; automatic checks can be changed in General settings. Checks run daily.
System profiling and automatic downloading/installing are disabled, including
old preferences. Scheduled update windows are suppressed during playback; the
application menu and General settings expose an available-version reminder.
Manual checks use the standard Sparkle UI.

Downloading and installing require user choices. Deferring a staged install is
mapped to Sparkle's cancellation choice; it does not leave an install-on-quit
task. While downloading/preparing an accepted update, ordinary quit focuses the
update UI so the user can cancel or install first. Once installation is chosen,
the existing asynchronous AppState shutdown runs. Update termination cannot use
the normal 10-second forced-success fallback: a waiting window is displayed and
installation waits for real cleanup. If cleanup never returns, the update waits.
The normal quit fallback is unchanged. A shared ownership gate prevents the
ordinary relaunch helper and Sparkle from controlling the same restart.

## Packaging

Run `Scripts/prepare-sparkle.py`, generate the Xcode project with XcodeGen, then
use the existing `Scripts/package-app.sh`. Packaging prepares the pinned runtime
again and supplies its exact path to Xcode. The Release path signs all nested
Sparkle executables, nested app/XPC bundles, and the framework inside out. SBOM,
checksum, source binding, architecture, minimum OS, signature and entitlement
checks still apply. The approved inventory is an exact set of 34 paths, replacing
the previous numeric 29-object assertion. Extra, missing or substituted paths fail.

Optional `OKVIDEOMAC_UPDATE_CONFIG` names a plist with `SUFeedURL`,
`SUPublicEDKey` (base64 32-byte Ed25519 public key), and `OKUpdateChannel`.
Distribution packaging defaults to the checked-in public configuration at
`Supporting/StableUpdateConfiguration.plist`. The stable HTTPS feed is
`https://github.com/yaolin-dev/OKVideoMac/releases/latest/download/appcast.xml`.
The distribution gate rejects local-test and unconfigured channels. The unsigned source template uses `unconfigured` and no URL/key;
it displays an unavailable state and makes no update request. Never commit a
private key. Archive and appcast signatures are generated after final packaging;
do not modify the DMG afterward. `SURequireSignedFeed`, pre-extraction validation
and an infinite signed-feed failure retention period are required by bundle gates.
Sparkle's upstream key-rotation behavior can accept a valid same-Team-ID Developer
ID archive when its EdDSA archive signature fails; signed appcast validation is
still required. Do not describe this as an unconditional two-signature AND check.

For explicitly local testing, `--mode local --local-acceptance --local-developer-id`
requires a captured source snapshot and `DEVELOPER_ID_APPLICATION`. It uses all
Developer ID signature/Library Validation gates, but the snapshot remains
`acceptanceOnly: true` and `publicReleaseEligible: false`. It cannot be notarized
through this option. Ordinary local ad-hoc and clean-commit distribution gates
are unchanged. Local updates use `local-test` and only `http://127.0.0.1:PORT`.
A build records its public configuration in the signed Info.plist. The local
server must be running for the test feed to work. This does not publish a release.

## Acceptance

Use AppUpdateTests plus existing playback, language-relaunch, history and Android
shutdown tests. SourceAudit tests reject policy drift and altered inventories.
Real Sparkle installation tests must verify old-process exit before new launch,
one launch only, preserved history, cancellation, tampered feed/archive rejection,
and delayed cleanup beyond 10 seconds. Stage-2 probe artifacts are test fixtures,
not installable user deliverables. Actual AirPods/Bluetooth and manual listening
remain separate hardware acceptance; simulation cannot mark them as passed.

## Stable feed publication

The first public updater build is 0.8.1 (134). Version 0.8.0 does not contain
Sparkle and must be upgraded manually. Local builds 131-133 used a loopback test
feed; install the formal build manually to move to the stable feed.

`package-app.sh --mode distribution --notarize` uses the pinned official Sparkle
tools only after Apple returns Accepted and the final DMG passes staple validation.
`create_update_feed.py` checks the archive checksum, matches the Keychain public
key to the signed App, generates an appcast with embedded release notes and no
deltas, and verifies the archive and feed signatures. Its enclosure uses the
immutable version-tagged DMG URL. The final DMG must not change after signing the feed.
The signed `appcast.xml` joins the source-release manifest/SHA256SUMS and is the
one additional public asset beyond the existing 15-file release layout.

Signing uses Keychain account `OKVideoMac-release` (override with
`OKVIDEOMAC_SPARKLE_KEY_ACCOUNT`); only the public key is checked into source.
Do not export a private key into the repository, build artifacts or logs. Keep
the signing account available for subsequent releases; replacing it requires
Sparkle's documented key-rotation process. Developer ID and notary credentials
remain the existing release identities.

## Published 0.8.2 update

The stable latest feed now offers 0.8.2 (135), with the same public key and HTTPS
feed used by the formal 0.8.1 (134) App. The final notarized/stapled DMG and signed
feed were verified after public download. The unmodified 0.8.1 App's native
Check for Updates UI detected 0.8.2; that verifies feed/version compatibility,
not a 24-hour scheduled-timer run or a complete updater installation. Automatic
checks still require consent and defer during playback. Users confirm download
and installation. See [release verification](RELEASE_VALIDATION_0.8.2.md).
