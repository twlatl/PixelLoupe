#!/bin/zsh
# Builds the JPEG XL encoder that Smart Previews use (RAW-116): libjxl, pinned below, as one static arm64 library
# with its headers, in Packages/JXLEncoder/libjxl.xcframework.
#
#   Scripts/build-libjxl.sh
#
# Needs git and CMake (brew install cmake). PixelLoupe only encodes with libjxl; Apple's RAW engine decodes JPEG XL
# itself. libjxl brings Highway, Brotli and skcms as its own submodules, at the commits it pins; nothing is taken from
# Homebrew or the system, so the result is the same on any Mac. The work happens in build/libjxl, which is kept for
# the next run (delete it to start over).
#
# It also writes PixelLoupe/Resources/libjxl-LICENSE.txt, the licenses of everything in the library, which ships in the
# app (THIRD_PARTY_NOTICES.md).
#
# To move to a newer libjxl, change version and commit together (git ls-remote --tags
# https://github.com/libjxl/libjxl.git), run this script, build and test, and check THIRD_PARTY_NOTICES.md still
# describes what's bundled.
set -euo pipefail
cd "$(dirname "$0")/.."

version=v0.12.0
commit=a7a9c787341cf703dede03c2009fa460cae5e5df
repository=https://github.com/libjxl/libjxl.git
output=Packages/JXLEncoder/libjxl.xcframework
licenses=PixelLoupe/Resources/libjxl-LICENSE.txt
work=build/libjxl
deployment_target=27.0

command -v cmake >/dev/null || { echo "CMake is needed: brew install cmake" >&2; exit 1; }

# Reproducible output: no timestamps in any archive (CMake's, libtool's or strip's), and source paths recorded
# relative to the checkout, so the same source and Xcode give the same bytes on any Mac.
export ZERO_AR_DATE=1
prefix_map="-ffile-prefix-map=$PWD/$work/src=libjxl -ffile-prefix-map=$PWD/$work/cmake=libjxl-build"
# Highway would compile every SIMD routine for several CPU targets (NEON, NEON with BF16, SVE, SVE2) and choose at run
# time; Macs have no SVE, so only the NEON baseline is built. That more than halves what libjxl adds to the app.
simd="-DHWY_COMPILE_ONLY_STATIC=1"

# The source, at the pinned commit, with only the submodules the library needs.
if [[ ! -d "$work/src/.git" ]]; then
  rm -rf "$work/src"
  git clone --quiet --depth 1 --branch "$version" "$repository" "$work/src"
fi
actual=$(git -C "$work/src" rev-parse HEAD)
if [[ "$actual" != "$commit" ]]; then
  echo "libjxl $version is at $actual, not the pinned $commit" >&2
  exit 1
fi
git -C "$work/src" submodule update --quiet --init --depth 1 third_party/highway third_party/brotli third_party/skcms

# A Release build of the static libraries: no tools, plugins, viewers, tests, docs or jpegli.
generator=()
command -v ninja >/dev/null && generator=(-G Ninja)
cmake -S "$work/src" -B "$work/cmake" "${generator[@]}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment_target" \
  -DCMAKE_C_FLAGS="$prefix_map" \
  -DCMAKE_CXX_FLAGS="$prefix_map $simd" \
  -DCMAKE_INSTALL_PREFIX="$PWD/$work/stage" \
  -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" \
  -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_TESTING=OFF \
  -DJPEGXL_ENABLE_TOOLS=OFF \
  -DJPEGXL_ENABLE_JPEGLI=OFF \
  -DJPEGXL_ENABLE_BENCHMARK=OFF \
  -DJPEGXL_ENABLE_EXAMPLES=OFF \
  -DJPEGXL_ENABLE_MANPAGES=OFF \
  -DJPEGXL_ENABLE_DOXYGEN=OFF \
  -DJPEGXL_ENABLE_VIEWERS=OFF \
  -DJPEGXL_ENABLE_PLUGINS=OFF \
  -DJPEGXL_ENABLE_JNI=OFF \
  -DJPEGXL_ENABLE_SJPEG=OFF \
  -DJPEGXL_ENABLE_OPENEXR=OFF \
  -DJPEGXL_ENABLE_SKCMS=ON \
  -DJPEGXL_BUNDLE_LIBPNG=OFF \
  -DJPEGXL_FORCE_SYSTEM_BROTLI=OFF \
  -DJPEGXL_FORCE_SYSTEM_HWY=OFF \
  -DJPEGXL_FORCE_SYSTEM_LCMS2=OFF \
  >/dev/null
cmake --build "$work/cmake" --config Release
rm -rf "$work/stage"
cmake --install "$work/cmake" --config Release >/dev/null

# One static library (libjxl with its color management, Highway and Brotli) and libjxl's public headers.
libraries=(
  "$work/stage/lib/libjxl.a"
  "$work/stage/lib/libjxl_cms.a"
  "$work/stage/lib/libhwy.a"
  "$work/stage/lib/libbrotlienc.a"
  "$work/stage/lib/libbrotlidec.a"
  "$work/stage/lib/libbrotlicommon.a"
)
for library in $libraries; do
  [[ -f "$library" ]] || { echo "Expected $library from the libjxl build" >&2; exit 1; }
done
rm -rf "$work/xcframework"
mkdir -p "$work/xcframework/Headers"
libtool -static -no_warning_for_no_symbols -o "$work/xcframework/libjxl.a" $libraries
strip -S "$work/xcframework/libjxl.a"
cp -R "$work/stage/include/jxl" "$work/xcframework/Headers/"
# libjxl_threads isn't in the library (Smart Previews encode tiles in parallel themselves), so neither are its headers.
rm -f "$work/xcframework/Headers/jxl/"{thread_parallel_runner,resizable_parallel_runner}{.h,_cxx.h} \
  "$work/xcframework/Headers/jxl/jxl_threads_export.h"
rm -rf "$output"
xcodebuild -create-xcframework -library "$work/xcframework/libjxl.a" -headers "$work/xcframework/Headers" \
  -output "$output" >/dev/null

# The licenses that come with the library, from the same source. Highway is offered under Apache-2.0 or BSD-3-Clause;
# PixelLoupe takes BSD-3-Clause.
{
  echo "PixelLoupe encodes JPEG XL with libjxl $version, built with the Highway, Brotli and skcms code it includes."
  echo "Their licenses follow."
  for part in "libjxl:LICENSE" "libjxl patent grant:PATENTS" "Highway:third_party/highway/LICENSE-BSD3" \
              "Brotli:third_party/brotli/LICENSE" "skcms:third_party/skcms/LICENSE"; do
    echo
    echo "==== ${part%%:*} ===="
    echo
    cat "$work/src/${part#*:}"
  done
} > "$licenses"

echo "libjxl $version ($commit) in $output ($(du -sh "$output" | cut -f1)); licenses in $licenses"
