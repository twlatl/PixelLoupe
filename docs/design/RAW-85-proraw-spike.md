# RAW-85 spike: Smart Previews for ProRAW and other LinearRaw DNGs

**Question:** the design's recipe for Smart Previews (decode through the RAW engine into a linear Rec. 2020 DNG)
fails for iPhone ProRAW, with ΔE00 7–19 at As Shot (see the [white-balance spike](RAW-85-white-balance-spike.md)). Is
there a recipe that works for DNG originals that are already demosaiced (LinearRaw)?

**Answer:** yes. Make the Smart Preview a **downsized copy of the original DNG**: decode its raw samples, average them
down to 2560 px (legitimate, since the data is linear), and write them back with the original's own color profile,
tone curve and gain map, in the original's two-IFD layout.

- **Fidelity:** uncompressed, it's visually identical to the original at every setting tried, white balance included
  (ΔE00 0.3–0.7 mean). With JPEG XL at distance 0.5 it's ΔE00 1.5–2.3 at about 0.7 MB.
- **Speed:** it renders 15× faster than the original.
- **Compression:** 8-bit lossy JPEG is **not** good enough for ProRAW (ΔE00 4.1–6.8), so ProRAW Smart Previews depend on
  the JPEG XL encoder.
- **PixelLoupe's own Photo Merge DNGs** need no special handling: the design's recipe reproduces them exactly.

## The ProRAW file

One iPhone 18 Pro Max ProRAW DNG (48 MP, used only for local measurements), big-endian.

**IFD0** holds:

- a full-size JPEG preview, `Orientation` 6, and EXIF and GPS directories (the EXIF includes Apple's MakerNote);
- the color profile: `ColorMatrix1/2` (illuminants A and D65), `AnalogBalance`, `AsShotNeutral` 1 1 1;
- `BaselineExposure` +5.35 EV, `BaselineSharpness`, `NoiseReductionApplied`, `ProfileName`, and a 257-point
  `ProfileToneCurve`.

**One SubIFD** holds the raw image:

- 8064 × 6048 LinearRaw, 3 samples at 10 bits;
- lossless JPEG (compression 7, predictor 7) in 48 tiles of 1008 px;
- a 1024-entry `LinearizationTable` to 16-bit, `BlackLevel` 0, `WhiteLevel` 65535;
- `NoiseProfile`, `DefaultBlackRender`;
- a 193 KB `ProfileGainTableMap` (a 12 × 16 × 257 local tone-mapping table in relative image coordinates; the engine
  defaults `localToneMapAmount` to 1.0 because of it).

There are no opcode lists and no default-crop tags.

## What was built

- **A lossless JPEG decoder** (ITU-T T.81 process 14; Huffman lookup on 16 bits, predictors 1–7, no restart intervals;
  about 150 lines). It decodes all 48 tiles in parallel and linearizes them through the table in **0.13 s** (M4 Pro).
- **A box filter** that averages the linear data down to 2560 × 1920 (0.06 s).
- **Proxies** written by patching the original file: the downsized image and a new raw SubIFD are appended and IFD0's
  `SubIFDs` is pointed at them, so every other byte stays as it was. Variants then drop or replace pieces to find what
  a writer that rebuilds the file from scratch must keep.

Comparison: ΔE2000 mean / p95 against the original rendered by `CIRAWFilter` at 2560 px with the same settings and
sharpening off, over every second pixel each way. The engine's defaults were left as they are on both sides
(local tone mapping included).

## Results

### Downsized copy, uncompressed (16-bit linear, LinearizationTable dropped)

| Setting | With the gain map | Without the gain map |
|---|---|---|
| As Shot (4954 K / +17.9) | **0.66** / 1.98 | 6.85 / 13.64 |
| 3000 K / 0 | **0.51** / 1.71 | 8.94 / 22.31 |
| 3500 K / 0 | **0.63** / 2.06 | 8.23 / 17.98 |
| 4500 K / −15 | **0.61** / 1.95 | 7.52 / 14.39 |
| 7500 K / +20 | **0.54** / 1.64 | 7.81 / 14.21 |
| 10000 K / 0 | **0.50** / 1.61 | 8.15 / 17.58 |
| Exposure +1.5 | **0.72** / 2.37 | 3.61 / 7.04 |
| Exposure −1.5 | **0.47** / 1.47 | 8.76 / 25.93 |

As Shot reads back exactly (4954.1 K / +17.89). The copy renders in 0.06 s against 0.92 s for the original at the same
size.

### Compressed tiles in the same layout

Size is the raw image only; the profile tags add about 194 KB, mostly the gain map.

| Tiles | Size | As Shot | 3000 K | Exposure +1.5 |
|---|---|---|---|---|
| 16-bit uncompressed | 30 MB | 0.66 / 1.98 | 0.51 / 1.71 | 0.72 / 2.37 |
| **16-bit JPEG XL, distance 0.5** | **496 KB** | **1.87 / 4.86** | **1.54 / 4.91** | **2.25 / 6.53** |
| 16-bit JPEG XL, distance 1.0 | 303 KB | 2.57 / 6.36 | 2.12 / 6.38 | 3.10 / 8.49 |
| 8-bit JPEG, q 0.95 | 737 KB | 5.78 / 14.35 | 4.14 / 10.87 | 6.49 / 18.27 |
| 8-bit JPEG, q 0.85 | 659 KB | 6.08 / 14.65 | 4.34 / 11.23 | 6.79 / 18.71 |

Tile recipes are the ones the JPEG XL spike found:

- **JPEG XL:** the codestream is tagged linear and the data stored linear.
- **8-bit JPEG:** the data is encoded with the sRGB curve, because the engine ignores `LinearizationTable` for lossy
  JPEG.

8-bit fails on ProRAW because ProRAW keeps the scene dark in the data and adds 5.35 EV at render time. That lifts 8-bit
shadow steps far more than on a camera RAW proxy (ΔE00 3.8–4.0 there).

### What a rebuilt file needs

| Variant (of the patched copy) | Opens | Local tone mapping | Engine NR / sharpening | As Shot ΔE00 |
|---|---|---|---|---|
| As patched | yes | 1.0 | supported | 0.66 |
| 256 px preview in IFD0 instead of the full-size one | yes | 1.0 | supported | 0.66 |
| No EXIF or GPS directory | yes | 1.0 | not supported | n/a |
| EXIF without Apple's MakerNote | yes | 1.0 | not supported | **0.31** |
| 256 px preview + EXIF without MakerNote | yes | 1.0 | not supported | **0.31** |
| No `NoiseProfile` | yes | 1.0 | supported | n/a |
| One IFD holding both the profile and the raw image (rebuilt from scratch) | **no**, while it carries the gain map | n/a | n/a | n/a |

- **The gain map needs the two-IFD layout:** IFD0 as a (small) preview carrying the profile, and the raw image in a
  SubIFD with the gain map. Every single-IFD proxy with a gain map failed to open, whatever its DNG version or sample
  format.
- **Apple's MakerNote is what turns on the engine's noise reduction and sharpening for ProRAW.** Dropping it is
  *better* for a proxy: the engine's noise reduction is tuned for the 48 MP original and re-runs on the 2560 px copy,
  which is why As Shot improves from 0.66 to 0.31. Without it, a ProRAW proxy behaves like the other Smart Previews
  (noise reduction and sharpening come from the shared pipeline). EXIF capture settings alone don't turn engine noise
  reduction on: a `LinearDNGWriter` DNG with ISO and shutter speed still reports it unsupported.
- **The writer can rebuild the file rather than patch it.** Moving the MakerNote, which often breaks maker notes,
  isn't needed, because it's dropped.

## Photo Merge DNGs

A stand-in merge was written as `LinearDNGWriter` writes one: linear Rec. 2020 Float16 at the reference's white
balance, `AsShotNeutral` 1 1 1, `ColorMatrix1` XYZ → Rec. 2020 at D65, headroom in `BaselineExposure`. The design's
Rec. 2020 recipe rendered it with **ΔE00 0.00** at As Shot, 3000–10000 K and +1 EV. A merge's color model already is
the proxy's, so its Smart Preview's pixels are exactly the engine's own reduced decode. Only compression adds error,
as measured in the JPEG XL spike.

## Recommendation

*Decided 2026-10-19: JPEG XL at distance 0.5 ships in v1, and ProRAW gets the downsized-copy recipe in v1.*

**Choose the recipe by the original's `PhotometricInterpretation`:**

- **LinearRaw (34892) from another app (ProRAW, linear DNGs from DNG converters):** downsized copy.
  - Decode the raw IFD's tiles (lossless JPEG with the decoder above, uncompressed or Deflate; JPEG XL and lossy JPEG
    sources can probably be decoded with ImageIO, but check their opcode lists; not tested).
  - Linearize through `LinearizationTable`, apply `BlackLevel`, and average down to 2560 px.
  - Write IFD0 (a small preview plus the profile and color tags: `ColorMatrix*`, `ForwardMatrix*`, `CalibrationIlluminant*`,
    `AnalogBalance`, `AsShotNeutral`, `BaselineExposure`, `ProfileToneCurve`, `ProfileHueSatMap*`, `ProfileLookTable*`,
    `ProfileName`, `Orientation`, Make/Model, DNG versions) and a raw SubIFD (the new tiles, `BlackLevel` 0,
    `WhiteLevel`, `DefaultBlackRender`, `ProfileGainTableMap`, `NoiseProfile`).
  - Copy EXIF without the MakerNote, for metadata only.
  - Opcode lists with pixel coordinates (GainMap and the like) would need scaling; ProRAW has none.
- **PixelLoupe's own merges (LinearRaw from `LinearDNGWriter`):** the design's Rec. 2020 recipe as it is. Telling them
  apart by `Software` = PixelLoupe isn't strictly needed: the downsized copy should give the same result for them
  (not tested).
- **CFA (mosaic) DNGs and proprietary RAW formats:** the design's Rec. 2020 recipe, plus the white-balance exposure
  correction.

**ProRAW needs JPEG XL tiles.** That ties it to the JPEG XL decision:

- ship ProRAW Smart Previews in the same PR as the JPEG XL encoder (distance 0.5, about 0.7 MB each);
- until then, don't build Smart Previews for LinearRaw DNGs from other apps.

Merges can have Smart Previews from v1.

Before building it, check:

- other ProRAW generations, and at least one linear DNG from Adobe DNG Converter (which may carry `ForwardMatrix`,
  HueSat or Look tables, or opcode lists);
- that a writer that rebuilds the file from scratch, rather than patching it, reproduces the patched results.

## Prototype

Scratch files, not committed, in the session scratchpad
(`/private/tmp/claude-501/-Users-tlee-Source-PixelLoupe/0769d6fe-e570-446f-a02c-09583a4fb728/scratchpad/proto`):

- `proraw/ljpeg.swift`: the lossless JPEG decoder;
- `proraw/main.swift`: decoding, downsizing, the patched variants and the comparisons;
- `merge/main.swift`: the stand-in merge;
- `exiftest/main.swift`: the EXIF check.

They use `dng.swift`, `common.swift` and, for the JPEG XL tiles, `jxl/jxlenc.c`.
