# Phase 4 Manual Playback Regression

Date: 2026-08-13

Decision state: **MANUAL USER VERIFICATION REQUIRED**

Stable set and the isolated media-core candidate must use the same app commit,
test host, source configuration and practical network conditions. The
candidate test App must remain separate from the installed Desktop App.

## Required Manual Matrix

Record fixture identity without copying copyrighted user media into the
repository. Mark unsupported capabilities `N/A` with the reason rather than
inventing a pass.

| Area | Required checks | Stable | Candidate | Notes / measured evidence |
| --- | --- | --- | --- | --- |
| VOD codecs | H.264, HEVC, AV1 if supported; AAC, AC3/EAC3 | pending | pending | |
| VOD formats | MP4, MKV, TS, HLS; 1080p, 4K, high bitrate, long-form | pending | pending | |
| Tracks | multiple audio tracks; embedded/external subtitles | pending | pending | |
| Seek | first, repeated rapid, forward/backward, large/small, paused/playing | pending | pending | |
| Lifecycle | open/play/pause/resume/stop/close/reopen/episode switching | pending | pending | |
| Subtitles | Chinese, ASS/SSA, SRT, switch, disable, visual correctness | pending | pending | |
| Live TV | first channel, same/different source, HLS/TS, 4:3/16:9 | pending | pending | |
| Live switching | sequential and rapid switching; exit/re-enter | pending | pending | |
| Visual | smoothness, HDR where supported, subtitle rendering, controls | pending | pending | |

## Performance and Stability Record

Use multiple comparable observations where practical; do not impose a 1%
threshold. Record VOD/live first-frame latency, median/P90 seek response,
channel-switch latency, steady/peak CPU, idle/playing/post-exit memory,
crashes, hangs, errors and decoder fallback differences.

Acceptance is PASS only when there is no user-perceptible degradation and the
measurements remain within reasonable run-to-run variance. Any compatibility
loss, obvious first-frame/seek/switch regression, CPU/memory regression,
crash, hang, or subtitle/audio/HDR loss is FAIL.

## Replacement Rule

Until every applicable candidate column has a credible pass and performance
evidence supports no material regression, the binding decision is:

**KEEP_STABLE_NATIVE_BINARIES**

Codex may record observable automated and UI smoke evidence separately, but it
must not convert subjective smoothness, HDR, subtitle appearance, or sustained
rapid-switch quality into a manual PASS without a real human verification.
