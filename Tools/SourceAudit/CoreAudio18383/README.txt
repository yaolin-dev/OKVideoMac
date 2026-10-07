CoreAudio #18383 regression checks (open-source OKVideoMac only)

Production patches:
  mpv-0.41.0-coreaudio-init-cleanup.patch: upstream af067b5ea8e5fe396ebd9d3f895e51a7e75b3c09
  mpv-0.41.0-coreaudio-late-hotplug.patch: upstream c5d391adba7bd024954d0df1e0405f5749f4d4ca
Both are unchanged upstream patches. The mpv v0.41.0 archive stays locked.
Two small follow-ups cover failures demonstrated by this harness:
  disposed-unit: clear the instance after init_audiounit disposes it, so the
                 outer failure cleanup added by #18383 cannot reuse it.
  hotplug-init-failure: undo partial listener registration when hotplug_init
                        fails; ao_get_device_list frees that context immediately.
No OKVideoMac Swift/native player lifecycle code is changed.

Exact-source fault test:
  python3 Tools/SourceAudit/CoreAudio18383/lifecycle.py \
    OKVideoMac/macOS/OKVideoMac/Vendor/Build/Source/mpv-0.41.0/audio/out/ao_coreaudio.c \
    /private/tmp/ok-audio-lifecycle

The harness extracts unmodified production function bodies into lifecycle.c.
CoreAudio and mpv helper APIs are mocks; libdispatch is real. ASan/UBSan are on.
It runs 200 rounds of success + 11 initialization failure cut points and
hotplug-only success + 3 failure cut points (3,200 contexts). Registered
callbacks are fired before/after freeing the contexts, and remaining listeners
and AudioUnits must be zero. This is simulated notification delivery, not a
hardware or exhaustive concurrent CoreAudio callback test.

Negative controls (keep source variants in separate test output directories):
  Unpatched 0.41.0, --case 6: hotplug_cb heap-use-after-free.
  Only the two upstream patches: invalid second AudioUnit cleanup.
  Upstream + disposed-unit: hotplug-only partial registration use-after-free.
  All four patches: all cases pass with unchanged assertions.

Native runtime.c:
  Compile with the selected libmpv headers/library and an rpath to that library.
  Pass a six-second local audio/video file and a six-second PCM WAV file.
  Uses vo=null and mute=yes, requires current-ao=coreaudio (never accepts null
  audio as a substitute), verifies time progress, pause stability, resume, seek,
  media replacement, 60 playback/destroy rounds, 200 device-list/create/destroy
  rounds, and 20 nonexistent-device failures. Checks RSS growth <= 32 MiB after
  warmup and thread growth <= 4. The path from dladdr is printed for verification.
  Run the same harness against a separately built ASan/UBSan libmpv; it must
  never be installed into the App. macOS leaks --atExit can check Release too.

Production delivery:
  build-libmpv.sh re-extracts the checksum-locked source, applies patches,
  rebuilds Release, runs bridge smoke, and writes coreaudio-build.json.
  package-app.sh rejects mismatched source/patch/library receipts and bundles
  them. verify-bundle.sh compares UUID and executable-text hash after relocation
  and signing. The standard local-acceptance snapshot workflow can package
  uncommitted source without changing the source-release acceptance standard.

Hardware acceptance remains NOT_TESTED until performed by the user:
  AirPods connect; AirPods removal/disconnect; Bluetooth reconnect;
  system output device switching; human listening.
