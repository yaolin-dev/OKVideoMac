# Picture in Picture — Stage 0 public API probe

Status: **the sample-buffer route failed its feasibility gate on macOS 14.8.9 (23J631), arm64**.
This is an isolated experiment. It is not a player feature, a replacement app, or a releasable OKVideoMac build.

## Scope and result

The experiment checks `AVPictureInPictureController` with `AVSampleBufferDisplayLayer` before investing in an mpv frame bridge.
The source contains no private frameworks, downloaded media, user configuration, network requests, or credentials.
The normal app source and installed Desktop app are unchanged.

| Check | Observation | Conclusion |
| --- | --- | --- |
| Optimized native build, macOS 12 target | Swift `-O`, local ad-hoc signature, strict signature verification | Passed for this experiment; not distribution signing/notarization |
| Synthetic sample-buffer rendering | Moving marker and frame/time label visible; layer ready and rendering | Passed |
| Sample-buffer live time range | `possible=false`, no playback-delegate queries; bounded start attempt expires | Failed |
| Sample-buffer finite time range | Same result after reinitializing the controller with an already-rendering layer | Failed |
| AVPlayerLayer positive control | Local H.264 fixture plays; `possible=true`; `didStart` and `active=true` | API activation passed |
| AVPlayer PiP actual pixels | User confirmed normal picture in the system PiP window: purple background, moving orange marker and AVPLAYER CONTROL label; tool capture was white | Passed by explicit user visual confirmation; no audio, pause/return or performance pass inferred |
| Minimize, pause, return in mpv PiP | Not reached | Not tested because prerequisite failed |
| Audio synchronization, HDR, resource/power limits | Not reached | Not tested |

The `isPictureInPictureSupported()` class-level result is true on this host. It does **not** establish support for every content-source type.
The SDK's macOS 12 availability annotations are insufficient evidence of working sample-buffer PiP.

Apple DTS acknowledged incorrect availability annotations in June 2026:
<https://developer.apple.com/forums/thread/830764>.
The associated independent macOS/tvOS reproducer is <https://github.com/jazzychad/PiPBugDemo>.
The result above is based on this experiment's local observations, not solely on those reports.

## Rebuild

Use a fresh output directory outside the repository. Xcode command-line tools and macOS video-encoding services must be available.

```sh
python3 Source/build.py --output /private/tmp/OKVideoMac-PiP-Probe-NewRun
```

The build produces `Build/OKVideo-PiP-Stage0.app`, a synthetic 12-second H.264 fixture, and `Evidence/build.json` containing binary/source hashes.
Existing output directories are rejected to avoid overwriting running or previously verified experiments.
The fixture generator may fail with AVFoundation error -11834 when a process sandbox prevents access to the video encoder; that is a build-environment failure, not the PiP result.

Launch only the experiment app. In order:

1. Confirm that the teal marker and frame counter move in `SampleBuffer Live`.
2. Press `Start PiP`; observe the bounded five-second result.
3. Choose `SampleBuffer VOD`, wait for rendering, and repeat.
4. Choose `AVPlayer Control`; confirm the orange marker and `possible=true`, then start PiP.
5. Record actual pixels separately from controller activation; do not mark visible playback passed without observing it.

The app writes a current `Evidence/api-probe.json` and a separate file for each launch. The probe intentionally permits a bounded start attempt when `possible=false` to document platform behavior; production UI should disable unavailable actions.
Exit via the app menu or Command-Q when finished. This app does not read or modify the normal player's preferences.

## Evidence validation

The original experiment's evidence is retained in its local output directory. Named snapshots preserve each tested mode.

```sh
python3 Source/verify_evidence.py /path/to/original/Evidence
```

This command checks consistency of a **failed** sample-buffer gate and an active AVPlayer control. It is not a PiP feature acceptance test.

## Next decision

Do not proceed to mpv frame export or Stage 1 under the current public sample-buffer assumption.
Reassess an IINA-style native window route using private PIP.framework against a public NSPanel floating-window route.
The first carries private-API compatibility/distribution constraints; the second must be described as a floating window rather than native system PiP.
AVPlayerLayer is a valid control, but replacing mpv with AVPlayer would require a separate source/codec/subtitle compatibility plan and is not implemented here.

No GitHub update, publication, standard-app packaging, or Desktop replacement is performed by these scripts.
