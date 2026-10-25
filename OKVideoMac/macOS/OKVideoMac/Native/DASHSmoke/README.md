# Native playback regression fixture

These 12-second H.264/AAC files contain generated test patterns and a 440 Hz
sine tone. No downloaded film, provider URL, token, or personal data is included.
They exercise SegmentTemplate with timeline, SegmentList byte ranges,
SegmentBase with global SIDX, relative URLs after an HTTP redirect, MP4, MKV
and HLS. SHA256.json records the immutable media inputs.

Run `Scripts/verify-dash-playback.py --library <libmpv.dylib> --ffmpeg <libavformat.61.dylib>`.
The test uses those exact libraries to decode both tracks and seek over a local
HTTP server which requires a Referer header and implements byte ranges. It is
also run against the final signed Release bundle by verify-bundle.sh.

Source generation: FFmpeg lavfi testsrc2=size=160x90:rate=12 and
sine=frequency=440:sample_rate=48000, 12 seconds, libopenh264 at 64 kbps with a
24-frame GOP and AAC at 32 kbps. DASH uses two-second segments. The single-file
variant uses global_sidx; SegmentBase references that index. Legacy containers
reuse the same encoded tracks without transcoding.

The FFmpeg 7.1.4 DASH patch resolves adaptation sets against the effective HTTP
response location already obtained by the demuxer. Previously the original
pre-redirect URL was used for their initialization/segment URLs. No other
demuxer or public library API is changed.

The static-MPD alternate-representation patch tolerates an inaccessible
encoding when another representation of that media type remains available.
Cancellation, allocation failure, partial stream creation and failure of the
last representation still fail normally. Dynamic manifest refresh is unchanged.
The unavailable-alternates fixture fails the first video and audio encoding
while requiring the remaining video and audio to decode and seek successfully.

The single-file seek patch exposes the underlying HTTP seekability only for
static whole-file representations without concatenated initialization data.
The 360-second seek fixture repeats the generated tracks and has a global
SIDX. A throttled HTTP server and small demuxer cache require nonzero Range
requests for both tracks after seeking to 300 seconds. This prevents sequential
downloading from being mistaken for a successful indexed seek.
