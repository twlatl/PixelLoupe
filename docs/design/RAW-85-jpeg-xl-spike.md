# RAW-85 spike: JPEG XL tiles for Smart Previews

**Question:** is it worth bundling libjxl (encoding only) so Smart Preview DNGs can use 16-bit JPEG XL tiles instead
of the 8-bit lossy JPEG tiles chosen for v1? See [the design](RAW-85-smart-previews.md).

**Answer:** yes, as a follow-up after v1 rather than a blocker. At the same file size, JPEG XL roughly halves what
compression adds to the error, and it cuts the worst shadow artifacts (the p99) by 35–40%. Apple's RAW engine reads both
formats natively, so switching later needs no migration: new Smart Previews would use JPEG XL, and existing ones keep
working. The cost is about 3 MB of static libraries and a pinned build script.

## What was measured

The photo and method are the design's: one 61 MP Sony ARW (`~/Source/PixelLoupe-Sample-Images/Panorama/DSC00245.ARW`)
with a 2560 × 1707 proxy rendered through `CIRAWFilter` with the same settings as the original. Pixels were compared in
CIELAB with ΔE2000 (every second pixel each way).

- **Recipe:** the same as the other proxies (linear Rec. 2020, neutral at D65, `AsShotNeutral` set to the original's,
  `BaselineExposure` carrying the headroom, the original's `shadowBias` when rendering).
- **Tiles:** 256 × 256, each a bare JPEG XL codestream (DNG 1.7, compression 52546).
- **Encoder settings:** libjxl 0.12.0, effort 7, decode speed 4.
- **Machine:** Apple M4 Pro (14 cores), tiles encoded in parallel.
- "Decode" is one fresh `CIRAWFilter` render of the whole proxy, opening the file included.

### Against the original at As Shot

| Proxy | Size | ΔE00 mean | p95 | p99 | Encode | Decode |
|---|---|---|---|---|---|---|
| Float16, uncompressed (floor) | 26.9 MB | 1.93 | 3.08 | 3.51 | n/a | 0.03–0.05 s |
| JPEG XL lossless | 13.1 MB | (= floor) | | | 0.14 s | not timed |
| JPEG XL, distance 0.1 | 2.82 MB | 2.17 | 3.58 | 4.52 | 0.29 s | 0.16 s |
| JPEG XL, distance 0.25 | 1.77 MB | 2.46 | 4.47 | 6.29 | 0.31 s | 0.14 s |
| **JPEG XL, distance 0.5** | **1.16 MB** | **2.83** | **5.72** | **8.44** | 0.30 s | 0.13 s |
| JPEG XL, distance 1.0 | 0.72 MB | 3.33 | 7.35 | 11.13 | 0.26 s | 0.13 s |
| JPEG XL, distance 1.0, effort 3 | 0.63 MB | 3.59 | 7.92 | 11.41 | 0.08 s | 0.12 s |
| JPEG XL, distance 2.0 | 0.44 MB | 3.88 | 9.04 | 13.66 | 0.26 s | 0.12 s |
| 8-bit JPEG, q 0.95 | 1.39 MB | 3.79 | 8.31 | 12.92 | not timed | 0.04–0.10 s |
| 8-bit JPEG, q 0.85 (v1 choice) | 1.22 MB | 3.97 | 8.82 | 13.77 | not timed | 0.04–0.10 s |
| Original ARW | 73 MB | n/a | | | | 0.41–0.68 s |

The lossless JPEG XL row wasn't compared; it should equal the float floor by construction. 512 px tiles were only 2–4%
smaller than 256 px ones, so 256 px stays, matching `LinearDNGWriter.tileSize`.

### With the photo pushed

ΔE00 mean / p99:

| Proxy | Exposure +1.5 | Exposure −2 | 7500 K / +20 | 4500 K / −15 | 3500 K / 0 |
|---|---|---|---|---|---|
| Float16 (floor) | 2.36 / 6.57 | 1.03 / 3.75 | 1.91 / 3.58 | 4.03 / 6.79 | 8.40 / 14.11 |
| JPEG XL d 0.25 | 3.05 / 8.85 | 1.35 / 4.34 | 2.35 / 5.59 | 4.32 / 8.14 | 8.62 / 14.32 |
| JPEG XL d 0.5 | 3.53 / 11.18 | 1.56 / 5.36 | 2.71 / 7.32 | 4.55 / 9.72 | 8.80 / 15.05 |
| 8-bit JPEG q 0.85 | 4.88 / 17.05 | 2.31 / 8.72 | 3.93 / 12.91 | 5.15 / 13.58 | 9.26 / 17.48 |

The white-balance rows are dominated by the engine's white-balance drift (the float floor), which compression can't
fix. That is the separate white-balance spike.

## Findings

1. **What compression adds, at equal size.** The float floor (ΔE00 1.93) is the RAW engine rendering a Linear DNG
   differently from the camera file; no codec can go below it. Above the floor, 8-bit JPEG adds +2.0 at 1.2 MB, while
   JPEG XL adds +0.9 at the same size (distance 0.5), +0.5 at 1.8 MB (distance 0.25) and +0.25 at 2.8 MB (distance
   0.1). The p99 is in the shadows, where 8-bit quantization shows once the tone curve or Exposure lifts it. There
   JPEG XL improves most: at Exposure +1.5 the p99 is 11.2 against 17.1.
2. **Equal quality, smaller files.** JPEG XL at distance 2.0 matches 8-bit JPEG at about a third of the size (0.44 MB
   against 1.22 MB). That's about 22 GB instead of 61 GB for 50,000 photos.
3. **Apple's engine reads JPEG XL tile values as the DNG's linear sample values and ignores the codestream's
   transfer function.** Tiles tagged sRGB with sRGB-encoded data decoded 5.7× too bright. Tiles tagged *linear* with
   linear data decoded within 0.3% of the float proxy at every distance. So the writer tags the codestream linear
   (Rec. 2100 primaries, D65), and libjxl still quantizes perceptually internally.
   - Lightroom does it differently. Its tiles are sRGB-tagged, and its DNG adds an `OpcodeList2` (beginning with a
     MapPolynomial) that maps the values back to linear after decoding.
   - Lightroom records `JXLDistance` 0.1, `JXLEffort` 7 and `JXLDecodeSpeed` 4 in tags **52553–52555**.
4. **Decoding is slower but still fast.** A JPEG XL proxy took 0.12–0.18 s against 0.04–0.10 s for 8-bit JPEG, still
   about 3× faster than the original. These are cold renders. Whether `CIRAWFilter` keeps the decoded tiles between
   slider changes in Develop wasn't measured; it should be checked before shipping.
5. **Encoding is cheap.** 0.26–0.31 s per photo at effort 7, on top of the 0.5 s RAW decode. Effort 3 is 0.08 s, at
   +0.26 ΔE00 and 12% smaller files at distance 1.0.

## What bundling costs

- **Size:** Homebrew's arm64 dylibs come to about 3.3 MB: libjxl 1.9 MB (encoder and decoder together; there's no
  encoder-only build), brotli encoder and common 0.8 MB, highway 0.1 MB, plus a color-management library (libjxl_cms
  0.1 MB with lcms2 0.3 MB, or the bundled skcms instead). A static build with dead stripping should come in under
  that. Only arm64 is needed, since the app targets macOS 27.
- **Build:** Homebrew's libraries can't ship (they link to `/opt/homebrew` and aren't ours to sign). The work:
  - add `Scripts/build-libjxl.sh`, which builds a pinned libjxl release as static arm64 libraries with CMake (tools,
    jpegli, benchmarks and lcms2 off; skcms on) into an XCFramework;
  - add a local Swift package with a small C shim (`jxlenc.c` in the prototype, about 50 lines) and a `binaryTarget`;
  - decide whether CI builds it (needs CMake on the `xcode-27` runner, a few minutes, cacheable) or the XCFramework is
    committed (several MB of binaries in git).
- **Licenses:** BSD-3-Clause for libjxl and skcms, MIT for brotli, Apache-2.0 or BSD-3-Clause for highway. That means
  new entries under "Bundled with the app" in `THIRD_PARTY_NOTICES.md`, `Credits.html`, and a `CreditsTests` case
  like Sparkle's. Check that libjxl's repository-level patent grant is reproduced if it has one; Homebrew's install
  ships only `LICENSE`.
- **Security:** encoding only. libjxl only ever sees pixels PixelLoupe produced and never parses files from outside.
  Decoding stays in Apple's RAW engine.
- **Code:** the tile encoder sits behind one function in `SmartPreviewWriter`. The DNG gains `DNGVersion` 1.7, the
  three JPEG XL tags, `BitsPerSample` 16 and `WhiteLevel` 65535. Everything else is shared with the lossy JPEG writer.

## Recommendation

*Decided 2026-10-19: JPEG XL at distance 0.5 is the v1 format, with libjxl bundled in v1. ProRAW Smart Previews need
it (see the [ProRAW spike](RAW-85-proraw-spike.md)). The recommendation below is what the spike said before that.*

Keep 8-bit lossy JPEG for v1, as decided. Make JPEG XL at **distance 0.5** the next Smart Previews PR: it's the same
size as v1's files with clearly better shadows. Distance 0.25 is the choice if 1.8 MB per photo is acceptable for
near-lossless quality. No migration is needed, because Apple's engine reads both formats. "Build Smart Previews" on
existing photos would upgrade them on request.

Before committing to it, check two things:

- that Develop's slider responsiveness on a JPEG XL proxy is no worse than on the original (finding 4);
- that a release build with the static libraries passes notarization.

## Prototype

Scratch files, not committed: `jxl/jxlenc.c` (the libjxl shim), `jxl/main.swift` (the writer, reusing `dng.swift`)
and `compare.swift`. They are in the session scratchpad
(`/private/tmp/claude-501/-Users-tlee-Source-PixelLoupe/0769d6fe-e570-446f-a02c-09583a4fb728/scratchpad/proto`).
libjxl 0.12.0 was installed with Homebrew for the spike (`brew uninstall jpeg-xl` removes it).
