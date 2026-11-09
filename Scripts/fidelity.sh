#!/bin/zsh
# Runs PixelLoupe's fidelity suite against Lightroom exports and opens the report.
#
#   Scripts/fidelity.sh /path/to/fixtures [report.html]
#
# The fixtures folder holds <family>/<case>/ directories (families: basic, curve, hsl, color-grading,
# detail, effects, lens, transform, crop, masks…), each with
#   source.<ext>    the photo
#   settings.xmp    its Lightroom develop settings (a sidecar, or a preset saved as XMP)
#   reference.tif   Lightroom's export: 16-bit TIFF, Display P3, 2048 px on the long edge
# The photos are large and live outside the repository; Scripts/fetch-fidelity-fixtures.sh downloads them.
set -euo pipefail
cd "$(dirname "$0")/.."

fixtures="${1:?usage: Scripts/fidelity.sh /path/to/fixtures [report.html]}"
report="${2:-$fixtures/report.html}"

TEST_RUNNER_PIXELLOUPE_FIDELITY_DIR="$fixtures" \
TEST_RUNNER_PIXELLOUPE_FIDELITY_REPORT="$report" \
  xcodebuild test -project PixelLoupe.xcodeproj -scheme PixelLoupe -destination 'platform=macOS' \
  "-only-testing:PixelLoupeTests/FidelityTests/lightroomExports()"

echo "Report: $report"
open "$report"
