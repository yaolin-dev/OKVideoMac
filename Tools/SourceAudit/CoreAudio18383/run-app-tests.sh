#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
# Existing test-only diagnostics use this condition for optimized Release tests.
# This build is a test host; package-app.sh builds the deliverable independently.
exec xcodebuild \
  -project OKVideoMac/macOS/OKVideoMac/OKVideoMac.xcodeproj \
  -scheme OKVideoMac -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/OKVideoMac-Audio18383-Tests \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES ENABLE_TESTABILITY=YES ENABLE_CODE_COVERAGE=NO \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=OKVIDEO_PERFORMANCE_TEST \
  'PRODUCT_BUNDLE_IDENTIFIER=com.okvideomac.audio18383.$(PRODUCT_NAME:rfc1034identifier)' \
  CODE_SIGN_ENTITLEMENTS=Supporting/OKVideoMac.dev.entitlements \
  -only-testing:OKVideoMacTests/PlayerAudioMemoryTests \
  -only-testing:OKVideoMacTests/PlayerSeekBoundaryRegressionTests \
  -only-testing:OKVideoMacTests/PlayerProgressInteractionTests \
  -only-testing:OKVideoMacTests/OKVideoMacTests/testBundledMPVClientInitializesAndShutsDownIdempotently \
  -only-testing:OKVideoMacTests/OKVideoMacTests/testPlayerLifecycleControllerPreservesOrRecreatesNativeClient \
  -only-testing:OKVideoMacTests/OKVideoMacTests/testPlayerLifecycleStrictReleaseDestroysOldClientBeforePublishingReplacement \
  -only-testing:OKVideoMacTests/OKVideoMacTests/testStaleCloseCannotDestroyAPlaybackThatClaimsOwnershipWhileCloseWaits \
  -only-testing:OKVideoMacTests/OKVideoMacTests/testStaleStopCannotStopAPlaybackThatClaimsOwnershipWhileStopWaits \
  test
