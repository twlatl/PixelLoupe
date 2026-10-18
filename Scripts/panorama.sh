#!/bin/zsh
# Merges the RAW-95 panorama samples at full resolution, as Photo Merge ▸ Panorama does, and compares
# the results with Lightroom's merges of them.
#
#   Scripts/panorama.sh [samples folder] [output folder]
#
# The samples folder holds the 12 DSC*.ARW photos and Lightroom's "LR Spherical Output.dng" and
# "LR Cylindrical.dng" (default ~/Source/PixelLoupe-Sample-Images/Panorama). The output folder gets
# the merged DNGs, <projection>-compare.jpg (ours above Lightroom's, and each at 100% below) and
# timings.txt (how long each step took, the memory used and the sizes).
set -euo pipefail
cd "$(dirname "$0")/.."

samples="${1:-$HOME/Source/PixelLoupe-Sample-Images/Panorama}"
output="${2:-${TMPDIR:-/tmp}/PixelLoupe-Panorama}"
mkdir -p "$output"

TEST_RUNNER_PIXELLOUPE_PANORAMA_SAMPLES="$samples" \
TEST_RUNNER_PIXELLOUPE_PANORAMA_OUTPUT="$output" \
TEST_RUNNER_PIXELLOUPE_PANORAMA_FULL=1 \
  xcodebuild test -project PixelLoupe.xcodeproj -scheme PixelLoupe -destination 'platform=macOS' \
  -only-testing:PixelLoupeTests/PanoramaSampleTests

echo "Merged panoramas and comparisons: $output"
open "$output"
