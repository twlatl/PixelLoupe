#!/bin/zsh
# Reads real DNG camera profiles (.dcp), renders real RAW photos with each of them, and compares the renderings with
# Lightroom's exports of the same photos and profiles (RAW-126).
#
#   Scripts/camera-profiles.sh /path/to/profiles /path/to/photos [output folder]
#
# The profiles folder holds .dcp files; the photos folder holds RAW files and, optionally, Lightroom exports named
# "<photo> - <profile name>" (DSC00384 - Classic Chrome.jpg). The output folder gets each photo rendered with
# Default and with every profile, and report.md: what each profile holds, each rendering's brightness, and the
# ΔE2000 (mean and 95th percentile) against Lightroom where there is an export. Nothing is added to the repository.
set -euo pipefail
cd "$(dirname "$0")/.."

profiles="${1:?usage: Scripts/camera-profiles.sh /path/to/profiles /path/to/photos [output folder]}"
photos="${2:?usage: Scripts/camera-profiles.sh /path/to/profiles /path/to/photos [output folder]}"
output="${3:-${TMPDIR:-/tmp}/PixelLoupe-CameraProfiles}"
mkdir -p "$output"

TEST_RUNNER_PIXELLOUPE_DCP_PROFILES="$profiles" \
TEST_RUNNER_PIXELLOUPE_DCP_PHOTOS="$photos" \
TEST_RUNNER_PIXELLOUPE_DCP_OUTPUT="$output" \
  xcodebuild test -project PixelLoupe.xcodeproj -scheme PixelLoupe -destination 'platform=macOS' \
  -only-testing:PixelLoupeTests/DNGCameraProfileSampleTests

echo "Renderings and report: $output"
open "$output/report.md"
