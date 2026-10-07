Open-source updater stages 1 and 2 only

Baseline: origin/main ede50b3d69364ba3e033a20eaa03f4842e3085de plus the
16 hash-verified CoreAudio #18383 fix files. See build/OpenSourceUpdatesStage2.
No commercial source, public release, production feed, or Desktop replacement.

ProbeDriver.swift scripts only user choices. Download, signed-feed/archive
verification, extraction, process-exit observation, replacement and relaunch
are performed by unmodified Sparkle 2.10.0, pinned in dependency-lock.json.
MiniApp.swift verifies real AppKit terminateLater with asynchronous work,
explicit cancellation and the same 10-second timeout as OKVideoMac. This
mini probe alone does NOT establish real AppState.shutdown correctness.

Test App bundles use unique IDs and an isolated /private/tmp directory.
Developer ID signing uses the existing signing identity; test Ed25519 keys
are generated separately in a private file, never in the login Keychain.
This probe uses loopback-only HTTP fixtures with all Sparkle signature checks
enabled. Production HTTPS, notarization, settings UI and reminder presentation
are separate later gates and must not be claimed verified by this probe.

Canceling staged installation uses Skip, not Dismiss: Sparkle can preserve a
dismissed staged installation for installation when the app exits.

Run on the host GUI session:
  python3 Tools/SourceAudit/UpdatesStage2/probe.py prepare
  python3 Tools/SourceAudit/UpdatesStage2/probe.py mini --case normal
Scenarios: normal, timeout, cancel-termination-once, cancel-download,
cancel-install, tampered-feed, tampered-archive. Cancel-install also quits the
old app normally and asserts that no installation occurs on this later quit.
EXPECTED_TIMEOUT verifies the timeout path and
is never reported as successful player cleanup.

Preparation / reproducibility
- Set DEVELOPER_DIR to a full Xcode installation and
  OKVIDEOMAC_UPDATE_PROBE_IDENTITY to an existing Developer ID signing identity.
- Download the pinned release archive to /private/tmp/ok-sparkle-2.10.0.tar.xz
  and extract it to /private/tmp/OKVideoMac-SparkleStage2-Dependencies.
  The prepare command verifies the locked SHA-256 before building.
- For real_build.py also set OKVIDEOMAC_BUILD_ROOT, OKVIDEOMAC_NODE_RUNTIME
  (Node 22), and OKVIDEOMAC_UPDATE_PROBE_BASE_APP to the previously verified
  baseline Release App. The probe requires matching UUIDs when relocating
  external dylibs from the freshly built host to this baseline's runtime.
- python3 Tools/SourceAudit/UpdatesStage2/real_build.py
- python3 Tools/SourceAudit/UpdatesStage2/probe.py real --case idle
- python3 Tools/SourceAudit/UpdatesStage2/probe.py real --case playing
- python3 Tools/SourceAudit/UpdatesStage2/probe.py real --case paused

Real App test boundaries
real_build.py copies source to a temporary tree, records every source hash and
exact instrumentation, and builds the original SwiftUI App, AppDelegate and
AppState. Production source files are not edited. The fixture supplies a silent
local WAV and metadata to the real PlayerLifecycleController. It requires
advancing native playback AND the original reliable-history condition before
pausing. AppState's history/shutdown code is unchanged apart from trace calls.
New-version startup reads the real isolated SQLite database. No fixture inserts
fake playback progress or changes the original acceptance thresholds.

RealProbe's restart gate is a prototype, injected into the temporary copy of
AppRelaunchCoordinator. Both directions, helper-in-flight, armed helper, and
admission release after helper failure are tested with deterministic helpers.
The actual Sparkle update must not spawn OKVideoMacRelauncher. Node/Android
shutdown methods run; active Node and emulator workloads are NOT_TESTED here.
Video rendering, full-screen playback, physical audio devices and human listening
are NOT_TESTED by this silent audio fixture.

Pinned product constraints for the subsequent implementation stage
SUAutomaticallyUpdate=NO; SUAllowsAutomaticUpdates=NO;
SUScheduledCheckInterval=86400; SUEnableSystemProfiling=NO;
SUVerifyUpdateBeforeExtraction=YES; SURequireSignedFeed=YES;
SUSignedFeedFailureExpirationInterval=0. No production feed URL or signing key
is configured. Native permission UI timing still requires application-level
gating after onboarding and outside active/full-screen playback. Scripted user
choices in these probes do not establish that UI timing requirement.

Sparkle 2.10.0 upstream supports a same-Team-ID, Developer-ID-signed DMG fallback
for EdDSA key rotation (SUUpdateValidator.m). Do not describe its policy as
unconditionally requiring both archive signatures to pass. Signed appcast
validation remains mandatory with failure expiration set to zero. The mutated
archive test verifies rejection before unarchiving, including both failed paths.

The existing production verify_sbom.py still requires exactly 29 Mach-O objects.
The fixture checks those baseline paths plus the independently listed 5 paths
in approved-framework-paths.json. Production Sparkle SBOM, signing, HTTPS feed,
notarization, consent/settings UI and update timeout policy are later gates.
No stage-2 fixture is a distributable release or a Desktop replacement.
