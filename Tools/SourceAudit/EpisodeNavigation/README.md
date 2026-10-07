# Local native episode-navigation acceptance

This creates a disposable Developer ID signed Release fixture; never install it on Desktop.
Set DEVELOPER_DIR, OKVIDEOMAC_BUILD_ROOT, OKVIDEOMAC_NODE_RUNTIME,
OKVIDEOMAC_UPDATE_PROBE_IDENTITY, and OKVIDEOMAC_NAVIGATION_BASE_APP to the verified packaged App.
Run `python3 prepare.py`, then `python3 prepare_media.py`. Launch the generated
`/private/tmp/OKVideoMac-EpisodeNavigation-Native/Template.app` through the normal GUI.
Preserve existing Run evidence under another name before rerunning.

The fixture uses generated silent WAV files with E1–E16 plus a second E16 resource.
A private provider supplies media; production startPlayback, renderer mount gate,
libmpv events, automatic/manual transitions, history, and shutdown remain unchanged.
An isolated bundle identifier, support/cache directories and credential service keep user data separate.
The production updater is disabled only in the disposable fixture.
Exact instrumentation and hashes are recorded in instrumentation.json.

Run/events.jsonl must end in PASS with no FAIL, and the process must exit normally.
Assertions cover natural EOF E14→E15, ambiguous E16 remaining stopped,
manual resource choice, pause/seek/resume, exact resource history, and three reopen/manual-next rounds.
The twelve-second choice-panel dwell permits an optional UI observation; the automatic
log does not certify screenshot/visual inspection or Bluetooth hardware/listening.
