#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 3 ]]; then
  echo "Usage: $0 /path/to/OKVideoMac.app /path/to/ReproNative /path/to/report" >&2
  exit 64
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STABLE_APP="$1"
REPRO_ROOT="$2"
REPORT_DIR="$3"
STABLE_FRAMEWORKS="$STABLE_APP/Contents/Frameworks"
CANDIDATE_FFMPEG="$REPRO_ROOT/prefix"
CANDIDATE_MPV="$REPRO_ROOT/mpv-prefix"
CAPABILITY_SOURCE="$PROJECT_DIR/Native/FFmpegSmoke/ffmpeg-capabilities.c"

case "$REPORT_DIR" in
  /|/Users|/System|/Library|/opt/local)
    echo "Unsafe report directory: $REPORT_DIR" >&2
    exit 64
    ;;
esac

mkdir -p "$REPORT_DIR/bin" "$REPORT_DIR/symbols" "$REPORT_DIR/links"

clang -arch arm64 -mmacosx-version-min=12.0 \
  -I"$CANDIDATE_FFMPEG/include" \
  "$CAPABILITY_SOURCE" \
  -L"$STABLE_FRAMEWORKS" \
  -lavfilter.10 -lavformat.61 -lavcodec.61 -lavutil.59 \
  -Wl,-rpath,"$STABLE_FRAMEWORKS" \
  -o "$REPORT_DIR/bin/stable-ffmpeg-capabilities"

clang -arch arm64 -mmacosx-version-min=12.0 \
  -I"$CANDIDATE_FFMPEG/include" \
  "$CAPABILITY_SOURCE" \
  -L"$CANDIDATE_FFMPEG/lib" \
  -lavfilter.10 -lavformat.61 -lavcodec.61 -lavutil.59 \
  -Wl,-rpath,"$CANDIDATE_FFMPEG/lib" \
  -o "$REPORT_DIR/bin/candidate-ffmpeg-capabilities"

"$REPORT_DIR/bin/stable-ffmpeg-capabilities" | LC_ALL=C sort -u \
  > "$REPORT_DIR/stable-ffmpeg-capabilities.txt"
"$REPORT_DIR/bin/candidate-ffmpeg-capabilities" | LC_ALL=C sort -u \
  > "$REPORT_DIR/candidate-ffmpeg-capabilities.txt"
diff -u "$REPORT_DIR/stable-ffmpeg-capabilities.txt" \
  "$REPORT_DIR/candidate-ffmpeg-capabilities.txt" \
  > "$REPORT_DIR/ffmpeg-capabilities.diff"

stable_paths=(
  "$STABLE_FRAMEWORKS/libavcodec.61.dylib"
  "$STABLE_FRAMEWORKS/libavfilter.10.dylib"
  "$STABLE_FRAMEWORKS/libavformat.61.dylib"
  "$STABLE_FRAMEWORKS/libavutil.59.dylib"
  "$STABLE_FRAMEWORKS/libswresample.5.dylib"
  "$STABLE_FRAMEWORKS/libswscale.8.dylib"
  "$STABLE_FRAMEWORKS/libmpv.dylib"
  "$STABLE_FRAMEWORKS/libOKMPVBridge.dylib"
)
candidate_paths=(
  "$CANDIDATE_FFMPEG/lib/libavcodec.61.dylib"
  "$CANDIDATE_FFMPEG/lib/libavfilter.10.dylib"
  "$CANDIDATE_FFMPEG/lib/libavformat.61.dylib"
  "$CANDIDATE_FFMPEG/lib/libavutil.59.dylib"
  "$CANDIDATE_FFMPEG/lib/libswresample.5.dylib"
  "$CANDIDATE_FFMPEG/lib/libswscale.8.dylib"
  "$CANDIDATE_MPV/lib/libmpv.2.dylib"
  "$CANDIDATE_MPV/lib/libOKMPVBridge.dylib"
)

summary="$REPORT_DIR/SUMMARY.txt"
: > "$summary"
for index in "${!stable_paths[@]}"; do
  stable="${stable_paths[$index]}"
  candidate="${candidate_paths[$index]}"
  name="$(basename "$stable")"
  stable_arch="$(lipo -archs "$stable")"
  candidate_arch="$(lipo -archs "$candidate")"
  if [[ "$stable_arch" != "$candidate_arch" ]]; then
    echo "Architecture mismatch: $name" >&2
    exit 1
  fi

  stable_minos="$(otool -l "$stable" | awk '/LC_BUILD_VERSION/{seen=1} seen && /minos/{print $2; exit}')"
  candidate_minos="$(otool -l "$candidate" | awk '/LC_BUILD_VERSION/{seen=1} seen && /minos/{print $2; exit}')"
  if [[ "$stable_minos" != "$candidate_minos" ]]; then
    echo "Deployment target mismatch: $name" >&2
    exit 1
  fi

  nm -gjU "$stable" | LC_ALL=C sort -u > "$REPORT_DIR/symbols/$name.stable.txt"
  nm -gjU "$candidate" | LC_ALL=C sort -u > "$REPORT_DIR/symbols/$name.candidate.txt"
  if ! diff -u "$REPORT_DIR/symbols/$name.stable.txt" \
    "$REPORT_DIR/symbols/$name.candidate.txt" \
    > "$REPORT_DIR/symbols/$name.diff"; then
    echo "Exported symbol mismatch: $name" >&2
    exit 1
  fi

  otool -L "$stable" | tail -n +2 | sed -E 's/ \(compatibility.*$//' | \
    awk -F/ '{print $NF}' | sed 's/^libmpv\.2\.dylib$/libmpv.dylib/' | \
    LC_ALL=C sort -u > "$REPORT_DIR/links/$name.stable.txt"
  otool -L "$candidate" | tail -n +2 | sed -E 's/ \(compatibility.*$//' | \
    awk -F/ '{print $NF}' | sed 's/^libmpv\.2\.dylib$/libmpv.dylib/' | \
    LC_ALL=C sort -u > "$REPORT_DIR/links/$name.candidate.txt"
  link_status="equal"
  if ! diff -u "$REPORT_DIR/links/$name.stable.txt" \
    "$REPORT_DIR/links/$name.candidate.txt" \
    > "$REPORT_DIR/links/$name.diff"; then
    link_status="different-see-report"
  fi

  stable_id="$(otool -L "$stable" | sed -n '2p' | sed -E 's/^[[:space:]]*//')"
  candidate_id="$(otool -L "$candidate" | sed -n '2p' | sed -E 's/^[[:space:]]*//')"
  stable_id="$(basename "${stable_id%% (*}") ${stable_id#* }"
  candidate_id="$(basename "${candidate_id%% (*}") ${candidate_id#* }"
  candidate_id="${candidate_id/libmpv.2.dylib/libmpv.dylib}"
  if [[ "$stable_id" != "$candidate_id" ]]; then
    echo "Install-name version mismatch: $name" >&2
    exit 1
  fi

  printf '%s\tarch=%s\tminos=%s\tsymbols=equal\tlinks=%s\n' \
    "$name" "$stable_arch" "$stable_minos" "$link_status" >> "$summary"
done

for required in \
  'decoder|h264|' 'decoder|hevc|' 'decoder|av1|' 'decoder|aac|' \
  'decoder|ac3|' 'decoder|eac3|' 'demuxer|mov' 'demuxer|matroska' \
  'demuxer|mpegts' 'demuxer|hls' 'protocol-in|http' \
  'protocol-in|https' 'protocol-in|tcp' 'decoder|ass|' \
  'hwdevice|videotoolbox'; do
  if ! grep -Fq "$required" "$REPORT_DIR/candidate-ffmpeg-capabilities.txt"; then
    echo "Required candidate capability missing: $required" >&2
    exit 1
  fi
done

stable_capability_sha="$(shasum -a 256 "$REPORT_DIR/stable-ffmpeg-capabilities.txt" | awk '{print $1}')"
candidate_capability_sha="$(shasum -a 256 "$REPORT_DIR/candidate-ffmpeg-capabilities.txt" | awk '{print $1}')"
printf 'ffmpeg_capabilities\tstable=%s\tcandidate=%s\tequal=yes\n' \
  "$stable_capability_sha" "$candidate_capability_sha" >> "$summary"

echo "Native candidate ABI/capability comparison passed: $REPORT_DIR"
