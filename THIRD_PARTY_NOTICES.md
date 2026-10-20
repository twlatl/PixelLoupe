# Third-party notices

PixelLoupe's own code is released under the [MIT License](LICENSE). It includes, or works with, the following
material from others.

## Bundled with the app

### LensFun lens database

- **What:** the camera and lens calibration data in the app's `Resources/LensFun/*.xml`, used by Develop's Lens
  Corrections.
- **From:** the [LensFun project](https://github.com/lensfun/lensfun) (`data/db`), © the LensFun contributors.
- **License:** [Creative Commons Attribution-ShareAlike 3.0 Unported](https://creativecommons.org/licenses/by-sa/3.0/).
  The full text ships next to the data, as `LensFun-LICENSE.txt`.
- **Changes:** none. The XML files are LensFun's own, unmodified, so they're distributed as part of a collection rather
  than as an adaptation. If they're ever edited, the edited files must stay under CC BY-SA 3.0 and say what changed.
- **Not used:** LensFun's code (LGPL). PixelLoupe reads the database itself and implements the published lens models
  (distortion, chromatic aberration, vignetting) in its own code.

### Sparkle

- **What:** `Sparkle.framework`, which checks for, downloads and installs new versions of PixelLoupe (PixelLoupe ▸ Check
  for Updates…).
- **From:** the [Sparkle project](https://sparkle-project.org) ([source](https://github.com/sparkle-project/Sparkle)), a
  Swift package pinned in `Package.resolved`. © Andy Matuschak, Elgato Systems, Kornel Lesiński, Mayur Pawashe and the
  other Sparkle contributors.
- **License:** the MIT License, with bundled components under BSD (bsdiff), MIT (sais), zlib (ed25519) and similar
  permissive licenses. The full text ships in the app as `Sparkle-LICENSE.txt`.
- **Changes:** none to Sparkle itself. Release builds leave out its XPC services, which only sandboxed apps use, and
  re-sign its helpers with PixelLoupe's Developer ID (`Scripts/release.sh`).

### libjxl (JPEG XL encoder)

- **What:** the JPEG XL encoder linked into the app, which compresses the tiles of Smart Previews (RAW-85). Only
  encoding is used; Apple's RAW engine decodes JPEG XL itself.
- **From:** the [JPEG XL reference implementation](https://github.com/libjxl/libjxl), © the JPEG XL Project Authors,
  built from a pinned release by `Scripts/build-libjxl.sh` into `Packages/JXLEncoder/libjxl.xcframework`. It includes:
  - [Highway](https://github.com/google/highway), © the Highway Project Authors;
  - [Brotli](https://github.com/google/brotli), © the Brotli Authors;
  - [skcms](https://skia.googlesource.com/skcms), © Google.
- **License:** the BSD 3-Clause License, with Google's patent grant for JPEG XL. Highway is under Apache-2.0 or
  BSD-3-Clause, and PixelLoupe takes BSD-3-Clause; Brotli is under the MIT License; skcms is under the BSD 3-Clause
  License. The full texts ship in the app as `libjxl-LICENSE.txt`, which the build script writes from the same source.
- **Changes:** none to the source. The build leaves out libjxl's tools, plugins, jpegli and thread pool.

## Used but not bundled

- **Adobe camera profiles and presets:** PixelLoupe reads profiles and Lightroom / Camera Raw presets that the user
  imports from their own Adobe installation. None of Adobe's files ship with PixelLoupe. "Adobe", "Lightroom" and
  "Camera Raw" are trademarks of Adobe Inc.; PixelLoupe isn't affiliated with or endorsed by Adobe.
- **Apple frameworks and SF Symbols:** used from the system under Apple's terms; nothing of Apple's is bundled.

## Keeping this file up to date

Add an entry here (and to `Resources/Credits.html`, which the About window shows) whenever a dependency,
dataset or asset from someone else is added, such as a Swift package. Its license must be compatible with
distributing PixelLoupe under the MIT License.
