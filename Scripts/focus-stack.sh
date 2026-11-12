#!/bin/zsh
# Stacks a folder of focus-bracketed photos, as Photo Merge ▸ Focus Stack does: a preview-size stack
# with its depth maps, then the full-resolution one.
#
#   Scripts/focus-stack.sh [samples folder] [output folder] [average | pyramid]
#
# The samples folder holds the frames (default ~/Desktop/Battery Stack Images). "average" or "pyramid"
# as the third argument stacks with Weighted Average or Pyramid instead of Depth Map (Pyramid has no depth maps). The output folder gets
# preview.dng (.tif when the frames aren't RAW), preview-depth.png, preview-depth-unsmoothed.png, the full-resolution <first>-Focus.dng
# (.tif when the frames aren't RAW) and timings.txt (how each frame was lined up, and how long each step took).
set -euo pipefail
cd "$(dirname "$0")/.."

samples="${1:-$HOME/Desktop/Battery Stack Images}"
output="${2:-${TMPDIR:-/tmp}/PixelLoupe-FocusStack}"
mkdir -p "$output"

TEST_RUNNER_PIXELLOUPE_FOCUS_SAMPLES="$samples" \
TEST_RUNNER_PIXELLOUPE_FOCUS_OUTPUT="$output" \
TEST_RUNNER_PIXELLOUPE_FOCUS_FULL=1 \
TEST_RUNNER_PIXELLOUPE_FOCUS_METHOD="${3:-}" \
  xcodebuild test -project PixelLoupe.xcodeproj -scheme PixelLoupe -destination 'platform=macOS' \
  -only-testing:PixelLoupeTests/FocusStackSampleTests

echo "Focus stack results: $output"
open "$output"
