#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"

python3 "$script_dir/generate_assets.py"
xcrun swift "$script_dir/make_demo_video.swift"
find "$script_dir/assets/video-frames" -type f -name 'frame-*.jpg' -delete
rmdir "$script_dir/assets/video-frames"

echo "Demo posters and original landscape video are ready."
