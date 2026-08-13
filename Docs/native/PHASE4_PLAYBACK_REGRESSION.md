# Phase 4 Stable vs Candidate Playback Regression

Date: 2026-08-13

Host: macOS 14.8.8 (23J620), arm64

App release: OKVideoMac 0.3.41 (62)

Candidate scope: the eight rebuilt FFmpeg/mpv/bridge media-core objects only;
all other App code and support libraries are the stable set.

Overall result: **OBSERVED CORE SMOKE PASS; FULL MATRIX AND SUBJECTIVE MANUAL
PASS NOT COMPLETE**

The stable Desktop App was never overwritten. The candidate was constructed as
an isolated App copy and ad-hoc signed for local testing. Both used the same
application data, configured sources, host and practical network conditions.
No test media was copied into the repository.

## Direct UI Evidence

| Scenario | Stable set | Candidate set | Result / boundary |
| --- | --- | --- | --- |
| 1080p H.264/AAC VOD trailer | frame rendered; duration `01:14`; continuous playback observed | same fixture rendered; duration `01:14`; continuous playback observed | PASS for this fixture |
| Pause / resume | pause control changed to play; resume changed back to pause | same | PASS |
| Paused backward seek | two rapid 10-second actions moved `57.246` to `37.246` seconds | exercised as part of a forward/backward sequence | PASS |
| Paused forward/backward sequence | two forward actions restored roughly 20 seconds and playback resumed | two forward plus two backward actions returned to `20.126`, then resumed at `20.406` | PASS for repeated small seeks |
| 4K HEVC MKV / AAC | present in the user's existing playback history; not replayed in the stable session during this audit | current progress `34:35 / 44:57`, then a decoded video frame rendered | candidate smoke PASS; not an A/B latency sample |
| Chinese text visible in 4K HEVC fixture | not replayed in stable session | Chinese text rendered in the decoded image | visual content observed, but player reported subtitle track disabled; does not prove subtitle-track rendering |
| Audio-track inventory | not inspected | one audio track enumerated | single-track fixture only |
| External-subtitle TS fixture | not replayed | source resolution failed before decoding: configured Quark cookie expired | NOT TESTED; external source credential gate, not a native failure |
| CCTV-1 live | live frame rendered and `正在直播` exposed | same | PASS for first live channel |
| Rapid next-channel actions | five rapid next/down actions moved CCTV-1 to CCTV-5+ | same | PASS for this short sequence |
| Exit/re-enter | VOD and live windows closed cleanly; App reused afterward | multiple VOD/live enter/exit cycles completed | PASS for observed cycles |

The screenshots were inspected during the live run but are intentionally not
placed in the source repository because they contain third-party broadcast and
preview frames.

## Timing Observations

These are wall-clock UI operation observations around accessibility-state
transitions. They include application, source and network work and are not
decoder-internal first-frame telemetry. Single observations are insufficient
for median or P90 claims.

| Operation | Stable | Candidate | Interpretation |
| --- | ---: | ---: | --- |
| initial VOD click to returned playback state | 8.128 s, already playing | 6.163 s, first returned state still connecting; next state rendered | INCONCLUSIVE for exact first frame |
| later same VOD history open | 4.9 s, already playing | 5.6 s, already playing | no obvious user-perceptible regression; not a controlled distribution |
| CCTV-1 click to returned live state | 3.543 s | 3.115 s | no observed regression |
| rapid live sequence to CCTV-5+ returned state | 1.161 s | 1.101 s | no observed regression |
| candidate 4K HEVC history open | not repeated | 4.872 s to active progress state; decoded frame observed immediately afterward | candidate-only smoke |

Therefore first-frame, seek-latency and live-switch *statistical* comparisons
remain `INSUFFICIENT DATA`. Nothing observed indicates an obvious degradation.

## CPU and Memory Samples

The same 1080p trailer was playing for five one-second `ps` samples.

| Set | CPU samples (%) | Mean CPU | RSS samples (KiB) | Mean RSS |
| --- | --- | ---: | --- | ---: |
| stable | 45.9, 50.3, 48.5, 48.4, 50.4 | 48.7% | 312560, 312576, 312512, 312576, 312576 | 312560 KiB |
| candidate | 45.6, 43.9, 46.6, 47.0, 48.8 | 46.4% | 308368, 308432, 308960, 309856, 310000 | 309123 KiB |

No obvious steady-playback CPU or RSS regression appears in this short sample.
Post-exit single samples were stable 254576 KiB and candidate 270256 KiB, but
the candidate process had previously exercised more fixtures (4K and live), so
the states are not comparable and no leak conclusion is drawn.

## Stability and Acceptance

- No crash or hang was observed in either UI session.
- No native decode, demux, protocol or bridge error was observed.
- One TS/external-subtitle source failed before playback because an external
  user cookie had expired.
- AV1, AC3/EAC3 playback, multi-audio switching, selectable ASS/SSA/SRT,
  sustained 4K/high-bitrate/long-form playback, HDR appearance, 4:3 live,
  cross-source live switching, P90 latency and repeated memory-leak testing
  were not completed.

The candidate does not satisfy the full replacement rule. Binding decision:

**KEEP_STABLE_NATIVE_BINARIES**

This is a stability-preserving decision, not a claim that the observed
candidate failed. The manual and broader performance matrix remains
`MANUAL USER VERIFICATION REQUIRED`.
