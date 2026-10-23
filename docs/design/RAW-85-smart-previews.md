# RAW-85: Smart Previews (design draft)

**Status:** design agreed on 2026-10-19 (see Decisions at the end). The format was revised the same day after three
follow-up spikes: [JPEG XL](RAW-85-jpeg-xl-spike.md), [white balance](RAW-85-white-balance-spike.md) and
[ProRAW](RAW-85-proraw-spike.md). Measurements come from prototypes on one camera model and one iPhone ProRAW file, so
treat the numbers as indicative, not final.

## Goal

A Smart Preview is a compact, editable stand-in for a photo's original file. With it, the photo can be developed,
compared and exported while the original is offline: on an unplugged drive, a NAS that isn't mounted, or a laptop away
from its archive. Lightroom Classic uses lossy DNGs about 2560 px on the long edge. Ours should behave the same way
from the user's side:

- **Build Smart Previews** at import (File Handling), and later from the Library for a selection.
- With the original missing, Develop, the Library's enlarged and full-screen views, Compare, Survey and Export use the
  Smart Preview. Edits are stored as usual (`Photo.adjustmentsData`) and apply to the original when it comes back.
- When the original is available, it is always used. A Lightroom-style "prefer Smart Previews for editing" setting
  is out of scope for now.

Not in scope: Lightroom's Build Standard/1:1 Previews (RAW-84), importing Lightroom's own Smart Previews (a possible
follow-up, below), and Smart Previews for videos.

## How previews work today

There are two tiers and nothing in between:

- **Thumbnails** are 768 px JPEGs at `Catalog.pixelloupe/Thumbnails/<photo UUID>.jpg`. At import they are made from
  the file's embedded preview. After every edit they are redrawn through the Develop pipeline. Lightroom imports seed
  them from Lightroom's previews (`ThumbnailStore`, `ThumbnailMaintenance`, `SeededThumbnails`).
- **Every larger view renders from the original** through `DevelopSource` → `AdjustmentPipeline`, at display size,
  and never saves the result: Develop, the Library's enlarged and full-screen views, Compare, Survey, Export and
  drag-out.

With the original offline, the Library and full screen stretch the 768 px thumbnail under a "could not be found"
banner. Develop shows "could not be found" with editing turned off. Compare and Survey show the thumbnail only, and
Export fails with `ExportError.unreadable`.

## What a Smart Preview is

### Camera RAW originals (proprietary formats and mosaic DNGs): a 2560 px Linear DNG

The proxy is the original decoded by the RAW engine at a scale of 2560 px on the long edge, before any look is
applied. It is written as a Linear DNG, the same kind `LinearDNGWriter` writes for Photo Merge, so Apple's RAW engine
opens it and the RAW-stage controls (Temperature, Tint, Exposure) still work on it. The pixels are stored as 16-bit
JPEG XL tiles (see "Storage format").

- **Pixels:** scene-linear Rec. 2020. They are decoded with the neutral set to D65, so no white balance is baked in.
  Engine sharpening and look are off (`exposure`, `baselineExposure`, `boostAmount`, `shadowBias` and
  `localToneMapAmount` all 0, gamut mapping off). The camera's default noise reduction is left on, which bakes in the
  engine's default NR at 2560 px. Highlights above 1.0 are kept by scaling the brightest pixel to 1.0 and adding the
  stops back in `BaselineExposure`, as Photo Merge does.
- **White balance:** `AsShotNeutral` is the original's as-shot neutral (from `CIRAWFilter.neutralChromaticity`)
  expressed in Rec. 2020, with `ColorMatrix1` = XYZ → Rec. 2020 and `CalibrationIlluminant1` = D65. In the prototype
  the proxy's As Shot read back as **5194 K / +12.1 against the original's 5194 K / +12.1**, so Temperature and Tint
  values mean the same thing on the proxy as on the original.
- **Upright:** orientation is applied and `Orientation` = 1. That is what `DevelopSource.nativeSize` already reports
  for RAW files (the decoded extent).
- **Original's size:** the DNG 1.4 proxy tags (`OriginalDefaultFinalSize` and related; check the exact tag set against
  the spec) record the original's full-resolution size, so geometry can be worked out without the original.
- **Engine defaults the proxy can't infer:** these go in `DNGPrivateData` as a small versioned plist. At minimum it
  holds the original's `shadowBias` (the engine defaults it to 3.0 for the ARW but 5.0 for the proxy; matching it took
  As Shot from ΔE00 3.2 to 1.9), its `localToneMapAmount`, and whether the built-in lens profile is applied by default.
  It also holds the white-balance table for the camera model (see "White balance far from As Shot" below), the
  original's size and modification date, used to spot a stale proxy, and the writer version.
- **Metadata:** Make, Model and UniqueCameraModel are copied from the original, along with EXIF capture settings, as
  `DNGMetadata` already carries for merges. The engine doesn't tune by them: a proxy with made-up names rendered
  identically.

### LinearRaw DNG originals (iPhone ProRAW and other apps' linear DNGs): a downsized copy

The Rec. 2020 recipe doesn't reproduce ProRAW (ΔE00 7–19 at As Shot). ProRAW renders with its own `ProfileToneCurve`
and `ProfileGainTableMap` (local tone mapping), which can't be carried over into a Rec. 2020 proxy.

The [ProRAW spike](RAW-85-proraw-spike.md) found the right recipe for DNGs that are already demosaiced
(`PhotometricInterpretation` LinearRaw). Decode the original's raw samples (lossless JPEG, about 150 lines), linearize
them, average them down to 2560 px and write them back with the original's own color profile, tone curve and gain map.

- **Layout:** IFD0 holds a small preview and the profile; a raw SubIFD holds the image and the gain map. The gain map
  only works in this two-IFD layout.
- **Apple's MakerNote is dropped.** That turns off the engine's noise reduction, which would otherwise re-run on the
  2560 px copy.
- **Fidelity:** ΔE00 0.3–0.7 at every white balance and exposure tried, with no white-balance correction needed,
  because the camera's own matrices come along.
- **Compression:** JPEG XL tiles at distance 0.5, like every other Smart Preview: ΔE00 1.5–2.3, about 0.7 MB
  (8-bit JPEG would have been too coarse for ProRAW, at ΔE00 4–7).
- **Source compressions:** ProRAW uses lossless JPEG (compression 7). Uncompressed and Deflate sources are
  straightforward. JPEG XL and lossy JPEG sources (for example Lightroom's own linear DNGs) and opcode lists with pixel
  coordinates weren't tested; a DNG the writer can't read gets no Smart Preview and is logged.

PixelLoupe's own Photo Merge DNGs are LinearRaw too, but they're already in the proxy's color model. The Rec. 2020
recipe reproduces them exactly (ΔE00 0.00 before compression), so they use it.

### Other photos (JPEG, HEIC, TIFF, PSD)

A 2560 px HEIC in the original's color space, opened through `DevelopSource`'s non-RAW path. Their originals already
take that path (`isRaw == false`, with exposure, white balance and noise reduction done by Core Image), so a proxy
behaves exactly like its original at a smaller size. A DNG would gain nothing here.

### Videos

No Smart Previews, as in Lightroom.

## Storage format: 16-bit JPEG XL tiles

Measured on one 61 MP Sony ARW (9504 × 6336), at 2560 × 1707. The original and each proxy were rendered with the same
RAW settings and compared pixel by pixel in CIELAB (ΔE00: under about 1 is invisible, 2–3 is noticeable side by
side). "Decode" is one render at 2560 px, excluding thumbnails and the rest of the pipeline.

| Proxy | Size | Opens in `CIRAWFilter` | ΔE00 at As Shot (mean / p95 / p99) | Exposure +1.5 (mean / p99) | Decode |
|---|---|---|---|---|---|
| Original ARW (reference) | 73 MB | yes | n/a | n/a | 0.40–0.57 s |
| Float16, uncompressed | 26 MB | yes | 1.9 / 3.1 / 3.5 | 2.4 / 6.6 | 0.03–0.08 s |
| 8-bit lossy JPEG tiles, q 0.95 | 1.39 MB | yes | 3.8 / 8.3 / 12.9 | 4.7 / 16.2 | 0.04–0.11 s |
| 8-bit lossy JPEG tiles, q 0.85 | 1.22 MB | yes | 4.0 / 8.8 / 13.8 | 4.9 / 17.1 | 0.04–0.11 s |
| 16-bit JPEG XL tiles, distance 0.25 | 1.77 MB | yes | 2.5 / 4.5 / 6.3 | 3.1 / 8.9 | 0.14 s |
| **16-bit JPEG XL tiles, distance 0.5 (chosen)** | **1.16 MB** | yes | **2.8 / 5.7 / 8.4** | **3.5 / 11.2** | 0.13 s |

The JPEG XL rows come from the follow-up [JPEG XL spike](RAW-85-jpeg-xl-spike.md), with libjxl 0.12.0 for encoding.

What the prototype found:

1. **Lossy JPEG DNGs (DNG 1.4 compression 34892) open in Apple's RAW engine**, but it **ignores `LinearizationTable`
   and `WhiteLevel`** for them and decodes the 8-bit tiles with the sRGB curve. Tiles encoded with the sRGB transfer
   function read back within 1% of the float values; gamma 2.4 read back 1.45× too bright, and linear 7× too dark.
   (Kept for reference: Smart Previews don't use lossy JPEG tiles.)
2. **ImageIO can decode JPEG XL but not encode it.** Lightroom's own DNGs now use JPEG XL (compression 52546, 16-bit;
   the Spherical panorama in the samples is one). Writing JXL ourselves means bundling libjxl (BSD-3) for encoding only.
   Apple's engine reads JXL tile values as linear samples and ignores the codestream's transfer function, so tiles are
   tagged linear. Lightroom instead tags them sRGB and maps the values back with an `OpcodeList2`.
3. **8-bit is the weak point of lossy JPEG.** Mean error is about 2 ΔE00 above the float proxy, and the p99 (around
   13) is in the shadows, where quantization is lifted by the tone curve and by Exposure.
4. **The original's slow step is the decode at scale.** A Smart Preview rendered several times faster than the 61 MP
   original at the same size (0.03–0.11 s against 0.40–0.57 s, each opening the file fresh), which a later "prefer
   Smart Previews" setting could use.

**Decision:** Smart Previews use **16-bit JPEG XL tiles at distance 0.5**, encoded with a bundled libjxl. That's
about 1.2 MB for a camera RAW proxy and 0.7 MB for ProRAW, or roughly 60 GB for 50,000 photos.

- **Why not 8-bit lossy JPEG:** at the same size, JPEG XL halves the error compression adds on top of the float floor
  of 1.9 (2.8 against 4.0 at As Shot) and cuts the shadow artifacts (p99 8.4 against 13.8). It's also the only option good enough for ProRAW.
- **Why not lossless:** up to 20 times larger (26 MB uncompressed, about 1.3 TB for 50,000 photos), which defeats the
  point.

The writer, from the spikes:

- **Tiles:** 256 × 256 (as `LinearDNGWriter.tileSize`), each a bare JPEG XL codestream (compression 52546). The
  codestream is **tagged linear** (Rec. 2100 primaries, D65) and holds linear 16-bit samples, because the engine reads
  tile values as linear and ignores the codestream's transfer function.
- **DNG tags:** `BitsPerSample` 16, `WhiteLevel` 65535, `DNGVersion` 1.7, and `JXLDistance` / `JXLEffort` /
  `JXLDecodeSpeed` (tags 52553–52555) set to 0.5 / 7 / 4.
- **Encode time:** about 0.3 s per photo (M4 Pro, tiles in parallel); effort 3 is 0.08 s if builds need to be faster.
- **libjxl** never sees anything but pixels PixelLoupe made, because decoding stays in Apple's RAW engine.
- **Minimum file size:** Apple's RAW engine won't open a DNG smaller than 100 KiB (102,400 bytes), whatever it holds;
  found while doing RAW-116. A very compressible proxy, such as a black frame or a tiny original, must be padded to
  that size, or it can't be opened.
- **Highlights:** near `WhiteLevel` the engine rolls highlights off toward neutral (its highlight recovery). The proxy
  maps its brightest pixel to `WhiteLevel`, so RAW-117 should check whether leaving a margin (for example the brightest
  pixel at half of white, with one more stop in `BaselineExposure`) brings highlights closer to the original's.

Before shipping, check that Develop's slider responsiveness on a JPEG XL proxy is no worse than on the original. A cold
proxy render was 0.12–0.18 s, but whether `CIRAWFilter` keeps decoded tiles between renders wasn't measured.

## Location in the catalog package

`Catalog.pixelloupe/Smart Previews/<photo UUID>.dng` (or `.heic`), flat like `Thumbnails/`, added to
`CatalogPackage` as `smartPreviewsURL(in:)`.

- **Inside the package**, as RAW-85 asks: `CatalogStore` describes each catalog as "a self-contained `.pixelloupe`
  package", and Smart Previews are most useful exactly when the catalog travels without its originals. Lightroom keeps
  them in a sibling `Catalog Smart Previews.lrdata`. That makes them easy to leave out of backups, but a moved catalog
  silently loses them.
- **The file system is the source of truth.** The package isn't indexed in Core Data. A `SmartPreviewStore` (alongside
  `ThumbnailStore`) lists the folder once, off the main thread, when the catalog opens, keeps the set of photo IDs
  that have one, and updates it as proxies are built or discarded. A Core Data attribute would only be needed for a
  Library filter or smart-collection rule ("Has Smart Preview"), which would mean model version 16 with a migration.
  That can be added later.
- Writes go to a temporary file in the same folder and are moved into place, as `ThumbnailStore.renderThumbnail` does.
- A removed photo's Smart Preview is deleted along with its thumbnail: both stay while the app runs, so undoing the
  removal brings them back, and are swept when the catalog next opens (`pruneOrphanedPreviews`).
- A master and its virtual copies share one Smart Preview, written under the master's ID.

## Choosing the original or the Smart Preview

### One place decides

Photo call sites build `DevelopSource(url: photo.fileURL)` themselves: `PhotoRenderer.render` and `writeJPEG`,
`ThumbnailStore.renderThumbnail`, `DevelopViewController.loadSource`, `CompareSource.load`, `AutoDevelop` (twice) and
`PhotoExporter.render`. Replace the URL with a small `Sendable` value resolved on the main actor:

```swift
/// Where a photo's pixels can come from. Resolved on the main actor; opened off it.
nonisolated struct PhotoSourceLocation: Sendable {
    var original: URL
    var smartPreview: URL?
}
```

`DevelopSource(location)` opens the original when it can be read, and otherwise the Smart Preview. It exposes which
one it opened (`isSmartPreview`). `FileAvailability.missingPhotoIDs` already tracks missing originals, but opening
should still fall back on an actual read failure, because a drive can disappear between checks. Photo Merge and Edit
In keep requiring the original.

### A Smart Preview pretends to be the original, at reduced resolution

The rest of the pipeline sizes things against the original's full-resolution pixels. It uses `nativeSize`,
`croppedSize`, `scale(toFit:)`, the grain size (`grainLayer`'s `scale`), the sharpen radius (`SharpenRenderer`'s
`scale`), zoom ratios and Export's pixel sizes. So a proxy-backed `DevelopSource`:

- reports the **original's** `nativeSize`, from the proxy tags;
- maps a requested `scale` (relative to the original) to `scaleFactor = scale / proxyScale` on the proxy;
- when asked for more than the proxy holds (Develop at 100%, the loupe, Compare zoomed in), returns the proxy enlarged
  to the extent the caller expects. The image is soft but correctly placed, and an indicator says so (below).

Spots, masks, crops and lens corrections are already in unit or frame coordinates, so they need no change.

### What the RAW engine can't do on a proxy

On a Linear DNG the engine reports no support for luminance or color noise reduction, sharpness, detail, or the
built-in lens profile (checked with `isLuminanceNoiseReductionSupported` and the other `is…Supported` flags).
`DevelopSource.baseImage` skips unsupported settings silently today, so on a proxy:

- **Noise Reduction:** use the Core Image noise reduction the non-RAW path already applies (`AdjustmentPipeline`'s
  `!source.isRaw` branch). The camera's default NR is already baked in at 2560 px. The result is an approximation; it
  doesn't need to match the original's.
- **Sharpening:** with Sharpen active, `SharpenRenderer` already does it in the pipeline, so it behaves the same. With
  Sharpen off, the original gets the engine's default sharpening and the proxy gets none. At 2560 px this made no
  measurable difference in the prototype.
- **Built-in lens profile** (many mirrorless RAW formats): bake it into the proxy when the camera always applies it
  (`rawDefaults.lensCorrection`). When it's the user's choice (Enable Profile Corrections), build the proxy
  uncorrected and record that. On a proxy, the Lens panel then says the built-in profile needs the original. Applying
  a LensFun profile instead would draw differently from Lightroom. (As built in RAW-120: the setting stays editable,
  since it applies to the original, and the panel says "The Built-in Lens Profile is applied to the original only.")

### White balance far from As Shot is the main fidelity risk

The engine's white-balance math on the proxy uses one Rec. 2020 matrix, while on the original it uses the camera's
own matrices. Measured with the float proxy, so compression is not a factor:

| Temperature / Tint | ΔE00 mean (float proxy) | Mostly |
|---|---|---|
| As Shot (5194 K / +12) | 1.9 | n/a |
| 7500 K / +20 | 1.9 | n/a |
| 4500 K / −15 | 4.0 | brightness (ΔL +3.8) |
| 3500 K / 0 | 8.4 | brightness (ΔL +9.3) |

The [white-balance spike](RAW-85-white-balance-spike.md) found the error is mostly brightness, and that an exposure
offset fixes most of it. The offset is `table(T, tint) − table(As Shot)`, from a 96-byte table (8 temperatures × 3
tints) of the gain between the proxy's and the original's linear output, applied through `CIRAWFilter.exposure` in the
proxy path. On three Sony frames:

- 3000 K went from ΔE00 12–14 to 1.6–4.0 with each photo's own table, and to 2.9–3.5 with one shared table;
- 3500 K went from 8–10 to 1.4–3.6;
- near As Shot on the cool side it costs a little (7500 K / +20: 0.9–1.9 → 1.4–3.0).

Color matrices through `linearSpaceFilter` didn't do better than the exposure offset.

**Decision:** a table takes about 4.5 s to build (24 extra decodes of the original), so v1 uses **one table per
camera model**:

- it's built from the first Smart Preview of each model, stored in the catalog, and copied into each proxy's
  `DNGPrivateData`;
- it applies to camera RAW proxies only; ProRAW copies keep the camera's own matrices and need no correction;
- the fidelity check in its PR should cover at least two more camera makers (for example Canon CR3 and Fujifilm RAF)
  and try fading the offset in only away from As Shot, where it currently costs a little.

*As built in RAW-121:* the temperature's part of the correction fades in between 40 and 90 mired cooler than As Shot.
On five frames of the Sony samples, with one table measured on the first (ΔE00 means, Smart Preview against
original at 640 px):

| Setting | Without correction | With it |
|---|---|---|
| 3000 K / 0 | 12.6–14.6 | 2.8–4.6 |
| 3500 K / 0 | 9.3–10.8 | 1.7–3.6 |
| 4500 K / −15 | 5.2–5.7 | 2.3–3.8 |
| 7500 K / +20 | 1.8–3.9 | 1.9–3.9 (within 0.15) |
| 10000 K / 0 | 4.3–5.2 | 3.2–4.5 |

As Shot was 2.7–4.2 on the same frames. Without the fade, 7500 K cost 0.3–0.9. The check runs on any folder of
camera RAW files (`PIXELLOUPE_WHITE_BALANCE_SAMPLES`); Canon and Fujifilm files still need to be put through it.

### What each part of the app does

| Feature | Original available | Original missing, Smart Preview exists |
|---|---|---|
| Develop | original (as today) | Smart Preview, editable. A "Smart Preview" label in the info line (Lightroom shows it under the histogram). Zoom past 2560 px is soft. |
| Library enlarged view, full screen, slideshow | original | Smart Preview, instead of the stretched thumbnail. The missing-file banner stays. |
| Compare, Survey | original | Smart Preview |
| Thumbnails after an edit | drawn from the original | drawn from the Smart Preview, and listed for a redraw once the original returns |
| Export | original | Smart Preview at up to 2560 px; the export summary lists which photos came from Smart Previews |
| Drag-out, Edit In, Photo Merge | original | not available (as today) |
| Auto (Light, White Balance), horizon detection | original | Smart Preview; these already work at 512–2000 px |

**Thumbnails:** generalize `SeededThumbnails` into a list of thumbnails not drawn from the original, with the reason
(Lightroom seed or Smart Preview). `ThumbnailMaintenance` redraws both once the original is readable. Without this,
`FileAvailability`'s check (is the file newer than its thumbnail?) would never notice the difference.

## Building, updating and discarding

- **Builder:** a `SmartPreviewBuilder` on the catalog. It's a queue with low priority (`.utility`), a few photos at a
  time, each `@concurrent`, and stops when the catalog closes, like `ThumbnailMaintenance`. Building one 61 MP ARW took
  about 0.5 s to decode at 2560 px and 0.3 s to encode. A 48 MP ProRAW took 0.13 s to decode its tiles and 0.06 s to
  downsize, plus the encode.
- **Import ▸ File Handling ▸ Build Smart Previews** (off by default, remembered per catalog, part of import presets).
  It queues the imported photos after the import finishes, so the import isn't slowed. Progress shows in the import
  summary or as a background activity. *Dependency:* main's import panel has only Destination. File Handling exists
  only on the unmerged RAW-80 → RAW-86 stack, which predates the PixelLoupe rename (162 commits ahead of main, 35
  behind). Either that stack lands first or the toggle lands in a later subtask.
- **Library ▸ Previews ▸ Build Smart Previews / Discard Smart Previews** for the selection, with the count of photos
  affected. These are menu commands without a Lightroom shortcut, so no new shortcut is needed.
- **Status:** under the histogram in Develop and the Library inspector, as in Lightroom: "Original", "Original + Smart
  Preview", "Smart Preview" (the original is missing), or "Original Missing" (and there's no Smart Preview). The total size could be shown with the catalog's other details later.
- **Stale proxies:** a proxy whose recorded source modification date or size no longer matches the original (for
  example after Edit In) is rebuilt when the original is next available. It keeps being
  used while the original is missing.
- **Export as Catalog:** add "Build / include Smart Previews" next to "Include available previews"
  (`ExportCatalogAccessory` already notes their absence).
- **Undo:** building or discarding Smart Previews changes no edits and isn't undoable, as in Lightroom.

## Delivery (one PR each, in order)

1. **libjxl:** the encoder, bundled.
   - `Scripts/build-libjxl.sh` builds a pinned libjxl release as static arm64 libraries with CMake (tools, jpegli,
     benchmarks and lcms2 off; skcms on) into an XCFramework.
   - A local Swift package wraps it with a small C shim (`pl_jxl_encode`, about 50 lines in the prototype).
   - CI either builds and caches it, or the XCFramework is committed.
   - Notices: `THIRD_PARTY_NOTICES.md`, `Credits.html` and a `CreditsTests` case (libjxl and skcms BSD-3-Clause,
     brotli MIT, highway Apache-2.0 or BSD-3-Clause).
   - Check that a notarized release build works.
2. **Proxy format for camera RAW files and other images:** a `SmartPreviewWriter`.
   - Camera RAW files get the Rec. 2020 Linear DNG with JPEG XL tiles, `DNGPrivateData` and proxy tags; the same path
     serves PixelLoupe's own merges. Other images get the HEIC proxy.
   - Tests use synthetic DNGs (`DNGFixtures`) and run a fidelity check against the sample RAW files when
     `PIXELLOUPE_PANORAMA_SAMPLES` is set.
3. **Proxy format for LinearRaw DNGs from other apps (ProRAW):** the downsized copy.
   - A lossless JPEG decoder, linearization, a box filter, and a two-IFD rewrite keeping the original's profile, tone
     curve and gain map, without the MakerNote.
   - Tests: decoder round trips with a test-only lossless JPEG encoder, and a fidelity check against a ProRAW sample
     when one is provided (none can live in the repository).
4. **Store and commands:** `CatalogPackage.smartPreviewsURL`, `SmartPreviewStore`, `SmartPreviewBuilder`, Library ▸
   Previews ▸ Build/Discard, status labels, cleanup when photos are removed.
5. **Using them:** `PhotoSourceLocation`, proxy-backed `DevelopSource` (scale mapping; the noise-reduction, sharpening
   and lens capability handling), every consumer in the table above, and thumbnail redraws. Includes the
   slider-responsiveness check on JPEG XL proxies.
6. **White-balance exposure correction** for camera RAW proxies.
   - Build a per-camera-model table from the first Smart Preview of each model, store it in the catalog and copy it
     into each proxy's `DNGPrivateData`.
   - At render time, add `table(T, tint) − table(As Shot)` to `exposure` in the proxy path of `DevelopSource.baseImage`.
   - The fidelity check covers more camera makers than the spike did.
7. **Export** from Smart Previews at up to 2560 px, with the export summary saying which photos used them.
8. **Import option and Export as Catalog**, after File Handling is on main.

Follow-ups, not part of RAW-85:

- importing Lightroom's Smart Previews (`Catalog Smart Previews.lrdata`; Apple decodes their JPEG XL DNGs);
- LinearRaw sources the downsized copy doesn't handle yet (JPEG XL or lossy JPEG tiles, opcode lists with pixel
  coordinates, `ForwardMatrix` or HueSat/Look tables), checked against more ProRAW generations and Adobe DNG Converter
  output;
- per-photo white-balance tables, if more cameras show that per-model tables aren't enough;
- "Has Smart Preview" in the Library filter.

## Decisions (2026-10-19)

1. **Compression:** 16-bit JPEG XL tiles at distance 0.5 (linear-tagged, 256 px tiles, effort 7, decode speed 4),
   encoded with **libjxl bundled in v1**. *Revised the same day:* the first decision was 8-bit lossy JPEG, changed after
   the JPEG XL and ProRAW spikes.
2. **When they're used:** only when the original can't be read. No "prefer Smart Previews for editing" setting yet.
3. **Export with the original missing:** export from the Smart Preview at up to 2560 px, and say so in the export
   summary.
4. **Location:** inside the package, at `Catalog.pixelloupe/Smart Previews/`.
5. **Recipe by kind of original:**
   - camera RAW files and mosaic DNGs: Rec. 2020 Linear DNG;
   - LinearRaw DNGs from other apps, including **iPhone ProRAW, in v1**: downsized copy of the original DNG;
   - PixelLoupe's own merges: Rec. 2020 Linear DNG (exact for them);
   - other images: 2560 px HEIC;
   - videos: no Smart Preview.

6. **White balance on camera RAW proxies:** correct it in v1 with an exposure offset from a **per-camera-model
   table**. The table takes about 4.5 s to build, once per model, and takes tungsten-on-daylight drift from ΔE00 about
   14 to about 3. No color-matrix correction. ProRAW copies don't need it.

## Appendix: how the prototype measured

Scripts in the session scratchpad (not committed): `proxy.swift` writes the proxies, `compare.swift` renders and
compares, and `exp` and `diag` test white balance and JPEG linearization. All runs used
`~/Source/PixelLoupe-Sample-Images/Panorama/DSC00245.ARW`:

- **The original** was rendered with `CIRAWFilter` at 2560 px, set as `DevelopSource.baseImage` sets it.
- **Each proxy** was rendered at scale 1 with the same settings, plus the original's `shadowBias`.
- **The comparison** rendered both to extended linear Rec. 2020, clipped them to 0–1 and converted to CIELAB (D65).
  Every second pixel in each direction was compared with ΔE2000. The calibration test used ΔE76.

The rest of `AdjustmentPipeline` runs after the decode and is the same for both, so only the decode was compared.

Limits:

- One camera model (three frames in the white-balance spike), plus one iPhone ProRAW DNG (the ProRAW spike).
- The first prototype hard-coded Make/Model; the white-balance spike showed the engine doesn't use them.
- No lens-profile camera was tested.
