# RAW-235 spike: a PixelLoupe RAW engine

**Question:** should PixelLoupe replace Apple's RAW engine (`CIRAWFilter`) with its own, built from scratch, so that
RAW files render the way Adobe Camera Raw renders them and people who migrate from Lightroom see their photos as they
left them? What would it take, what would break, what does every new camera cost afterwards, and how long would it be?

**Answer: yes, but not from scratch and not all at once.** The engine is the ceiling on fidelity: the RAW-125
prototype showed that most of the remaining gap to Lightroom is in Apple's base rendering, which no table on top of it
can change, and RAW-234 and RAW-137 are two more faces of the same thing (Apple's white-balance scale and its baseline
exposure are its own). Apple's engine has no input for a camera profile, a matrix or a tone curve, so the only way to
render like Adobe is to own the pipeline from the sensor values up. The colour model Adobe uses is public: the DNG
specification defines it in two chapters, and Adobe's own SDK implements it under a licence that allows any use. What
is *not* available is Adobe's per-camera colour data (its `.dcp` profiles, which cannot be redistributed) and the
camera makers' compressed formats (Nikon's HE/HE\* has no open decoder five years on). So the plan is:

1. **Build the engine on DNG first.** Everything a renderer needs is specified for DNG, PixelLoupe already reads and
   writes DNG (TIFF reader, lossless JPEG, JPEG XL, `LinearDNGWriter`), and ProRAW, Smart Previews and Photo Merge are
   DNGs. A DNG converted by Adobe's free DNG Converter carries Adobe's own matrices for that camera, legitimately, so
   the engine can be measured against Lightroom on the same colour data before a single native format is touched.
2. **Feed native files through LibRaw** (1,284 cameras, LGPL 2.1 or CDDL, C++), bundled the way libjxl already is,
   in an XPC service for crash isolation. PixelLoupe's part is the mosaic → image pipeline; the format zoo stays
   someone else's problem, with Apple's engine kept as a per-photo fallback for what LibRaw can't read.
3. **Make the engine a per-photo process version**, as Adobe does: photos already edited keep Apple's rendering until
   the user updates them, new imports use the new engine once it clears the fidelity bar, and the migration is opt-in
   and reversible.

Estimated at this project's cadence: a 2-week prototype with a go/no-go, then about 3 months to parity with today's
features plus Adobe-profile rendering, in roughly 70–100 PRs. Each new camera afterwards costs about a day when it uses
a known codec, and is out of PixelLoupe's hands when it doesn't. Details in [Scope and timeline](#4-scope-and-timeline)
and [Recommendation](#recommendation).

## Why the engine is the ceiling

What PixelLoupe has measured so far, all against Apple's rendering:

- **RAW-125** (camera-matching profiles, [the prototype](RAW-113-prototype.md)): a 17³ table fitted on Apple's
  Default takes X-T1 Classic Chrome to ΔE00 1.15 mean / 2.98 p95 against the camera's JPEG, and Lightroom is still
  closer on every photo compared, clearly at ISO 3200 (1.13 against 0.79) and on p95 everywhere. "The gap is in
  detailed areas, where Apple's base differs from the camera's." Ted put RAW-127 to RAW-135 on hold for this.
- **RAW-234:** As Shot on the same CR2 reads 6,166 K / +8.5 in PixelLoupe and 6,350 K / +11 in Lightroom. Both start
  from the camera's recorded neutral; each converts it to Kelvin and tint through its own camera matrices. The scales
  differ per camera, and a Lightroom catalog's Custom white balances import about 180 K off on that photo.
- **RAW-137:** Apple renders the X-T1 at a baseline of −0.70 EV and ignores the push the camera records at high ISO
  (`RawExposureBias`, −2.31 EV at ISO 6400), so photos open up to 1.5 EV darker than the camera's JPEG.
- **RAW-85** ([white-balance spike](RAW-85-white-balance-spike.md)): the engine "does something white-balance-dependent
  after" its linear stage, so even a perfect matrix through `linearSpaceFilter` lands ΔE00 1.9 from its own As Shot,
  and it re-runs the whole decode for every white-balance change (0.2–0.3 s a point even at scale 0.05).
- **This spike's benchmark** ([Measurements](#measurements)): a white-balance change costs a full re-decode, 0.08 s
  (22 MP) to 0.32 s (45 MP) at full size on an M4 Pro.

Apple's engine is a black box with about 45 knobs and no profile input. Its colour, tone and demosaic are whatever
decoder version the OS ships (RAW 6 to RAW 9; `CIRAWFilter.decoderVersion`), updated "eight times" since 2006 for
"784 models" ([WWDC26 session 305](https://developer.apple.com/videos/play/wwdc2026/305/)), and PixelLoupe doesn't pin
the version, so a macOS update can move every photo's rendering under the fitted tables (RAW-113 decision 17 plans
re-fits for exactly that). Everything PixelLoupe builds for Lightroom fidelity (slider mappings in `LightroomScales`,
the per-pixel Shadows of RAW-230/231, imported Adobe looks, the planned DCP support of RAW-126) sits on a base it
can't see into.

## What PixelLoupe takes from Apple's engine today

Ten files call `CIRAWFilter`; one of them matters.

| Where | What it uses the engine for |
|---|---|
| `Develop/DevelopSource.swift` | The wrapper. Opens the file, reads the defaults (`neutralTemperature`/`Tint`, noise reduction, `sharpnessAmount`, `detailAmount`, `isLensCorrectionSupported`/`Enabled`), and per render sets `scaleFactor`, white balance, `exposure`, noise reduction, sharpening (0 when the pipeline sharpens) and the built-in lens profile. `asShotWhiteBalance` is the engine's neutral. `shadowsReference` (RAW-231) is measured on its default decode. Everything after `baseImage` is PixelLoupe's: `LensCorrector`, orientation, `TransformRenderer`, `AdjustmentPipeline` (retouch, red-eye, highlight/shadow filter, Adobe look cubes, the `ColorLUT` cube with tone, curves, colour, black and white and per-pixel Shadows, sharpening, masks, Portrait Lighting, Rim Light, crop, vignette, grain). |
| `SmartPreviews/SmartPreviewWriter.swift` | The "linear decode": exposure, baseline exposure, boost, shadow bias and local tone mapping at 0, gamut mapping off, neutral at D65, sharpening off, rendered to linear Rec. 2020 and written as a 16-bit DNG with JPEG XL tiles. Records `shadowBias`, `localToneMapAmount` and the lens flags so the proxy can be rendered with the original's look. |
| `SmartPreviews/SmartPreviewWhiteBalance.swift` | A per-camera-model exposure-correction table (RAW-121), built by re-decoding at 24 white balances, because a proxy's white balance drifts in brightness away from As Shot. |
| `SmartPreviews/SmartPreviewWriter+DNGCopy.swift` | ProRAW and other LinearRaw DNGs: sizes and defaults only; the pixels are decoded by PixelLoupe's own lossless JPEG decoder. |
| `Merge/HDRMerger.swift`, `Merge/PanoramaMerger.swift` | Each frame's linear decode (the same recipe), with the lens profile on or off, merged in linear Rec. 2020 and saved by `LinearDNGWriter`. |
| Tests | `LinearDNGWriterTests`, `PanoramaSampleTests`, `SmartPreviewCopyTests`, `SmartPreviewWriterTests`. |

Properties in use: `outputImage`, `exposure`, `baselineExposure`, `boostAmount`, `shadowBias`, `localToneMapAmount`,
`isGamutMappingEnabled`, `scaleFactor`, `neutralTemperature`, `neutralTint`, `neutralChromaticity`, luminance and colour
noise reduction, `sharpnessAmount`, `detailAmount`, `isLensCorrectionSupported`/`Enabled`, and the `is…Supported`
flags. `decoderVersion` is left at the default.

Apple decodes RAW files in two more places that aren't `CIRAWFilter` but are the same engine: **grid thumbnails** at
import (`Thumbnails/ThumbnailStore.swift`, through ImageIO) and **metadata** (`Import/ImageMetadata.swift`,
`Library/Inspector/FileMetadata.swift`, `Develop/ShootingInfo.swift`, all `CGImageSource` properties). Thumbnails must
follow whatever renders Develop (the shared-pipeline rule in `SKILLS.md`); metadata can stay on ImageIO.

PixelLoupe already owns pieces an engine needs: `DNG/TIFFReader`, `TIFFDirectory` and `TIFFBuilder`; `DNG/LosslessJPEG`
(ITU-T T.81 process 14, any precision to 16 bits, predictors 1–7; 48 ProRAW tiles in 0.13 s); `Merge/LinearDNGWriter`;
`Packages/JXLEncoder` (libjxl built as an xcframework by `Scripts/build-libjxl.sh`, the precedent for bundling a C/C++
library); `LensFunDatabase` (CC BY-SA 3.0 XML, bundled), `LensKernels` and `TransformRenderer` (`CIKernel` geometry);
the `.ci.metal` kernels in `Merge`; `ColorLUT` (the 3D-table pipeline); `WhiteBalanceEstimator` and
`ChromaticAberrationEstimator`; `AdobeProfile` (`.xmp` look tables); a 25,160-file maker-note parser prototyped in
RAW-113 (Fujifilm, Nikon, Canon and Sony look tags).

## Where the pixels could come from instead

| Option | What it is | Verdict |
|---|---|---|
| **A. Stay on Apple, normalise around it** | Fix RAW-137 (Fujifilm push) and RAW-234 (shift As Shot to Lightroom's scale from the maker-note neutral and a D65 matrix), fit profiles on Apple's base (RAW-128→135). | Cheapest and already designed, but RAW-125 found its ceiling: Lightroom stays closer in detailed areas, every fit is tied to a decoder version, and Adobe Standard/Color can never be applied as Adobe applies them. Keep as the fallback engine, not the plan. |
| **B. Apple's linear output + our colour** | Take the Smart Preview "linear decode" and undo Apple's matrix per camera. | Rejected: the matrix is unknown and RAW-85 found white-balance-dependent processing after the linear stage. |
| **C. Own pipeline on top of LibRaw's unpack** | LibRaw reads the file to sensor values plus black, white, CFA, crop, white balance and a D65 matrix; PixelLoupe demosaics and renders. | The decoder part of the recommendation. LibRaw's rendering is explicitly not production quality and not developed further, which is fine: only `unpack` is wanted. |
| **D. Everything from scratch, in Swift** | Own parsers and codecs for NEF, CR2, CR3, RAF, ARW, RW2, ORF, PEF… | Rejected for v1: no Swift decoder exists (the two LibRaw wrappers are pre-production), the codecs took the open-source projects 2–3 years each (CR3, Fujifilm compressed, Panasonic v8) and one is still closed (Nikon HE). Own codecs can replace LibRaw's one format at a time later if ever wanted. |
| **E. DNG as the engine's native input** | The engine reads DNG only; native files reach it through LibRaw (C) or, for people who want Adobe's colour data, through Adobe's free DNG Converter at import. | The core of the recommendation. The format is fully specified (colour model, opcodes, gain maps, JPEG XL), PixelLoupe reads and writes it already, and a DNG Converter copy carries Adobe's Adobe Standard profile for the camera, which Adobe's embed policy allows to be used "for any DNG". |

The hard part turns out not to be the pipeline, whose maths is published, but the **per-camera colour data**. Adobe's
profiles are copyrighted (`ProfileCopyright "Copyright 20xx Adobe Systems, Inc."`), their embed policy allows copying
Adobe Standard for DNG files only ("may not be used to process non-DNG files", DNG spec p. 52) and Camera Matching
profiles only embedding, and no Adobe licence permitting redistribution was found. Every open-source engine copies
Adobe's D65 matrices out of DNG Converter output (dcraw, LibRaw and RawTherapee say so in their source; rawspeed PRs
cite "Adobe DNG Converter 13.0"; darktable reads rawspeed's table since 2022) with no licence from Adobe. See
[Supporting new cameras](#3-supporting-new-cameras-maintenance) for how PixelLoupe would source its own.

## 1. The tasks

The engine is a chain of stages between the file and `DevelopSource.baseImage`. For each: what it does, what exists,
what is new, and where it's specified.

### 1.1 Container and codec: file → mosaic plus metadata

- **DNG reader** (new, on `TIFFReader`): IFD0 and SubIFDs, CFA and LinearRaw, 8–16-bit integer and float,
  uncompressed, lossless JPEG (exists), Deflate (`libcompression`), lossy JPEG 34892 (ImageIO), **JPEG XL 52546**
  (DNG 1.7; `Packages/JXLEncoder` bundles the encoder only, so the decoder half of libjxl is added),
  `ColumnInterleaveFactor` (1.7.1), `LinearizationTable`, `BlackLevel` (+ repeat pattern, `DeltaH`/`DeltaV`), `WhiteLevel`,
  `ActiveArea`, `DefaultCropOrigin`/`Size`, `DefaultScale`, `CFAPattern`/`CFARepeatPatternDim` (X-Trans is 6×6),
  `AsShotNeutral`/`AsShotWhiteXY`, `BaselineExposure`, the profile tags (below), `OpcodeList1/2/3`, `NoiseProfile`,
  `ProfileGainTableMap`(2), `ExtraCameraProfiles`. DNG spec 1.7.1.0 Ch. 3–5 (pp. 20–31, 99).
- **LibRaw unpack** for native files (new): `open_file` → `unpack` → `rawdata` (the mosaic as `UInt16`), `sizes`
  (raw and active area, crop), `color` (black and per-channel black, maximum, `cam_mul` As Shot, `cam_xyz` D65 matrix
  from `colordata.cpp`), `idata` (make, model, CFA `filters`/`xtrans`), `other`/`makernotes` (ISO, lens, and the
  brand-specific tables LibRaw already parses). Bundled as an xcframework by a script like `Scripts/build-libjxl.sh`
  (LibRaw has no CMake; its autotools or `Makefile.dist` build, or the unmaintained `LibRaw-cmake`). Run in an **XPC
  service**: LibRaw's 2026 point releases are all fuzzing and CVE fixes, and a crash in a 60 MB file must not take
  the catalog down. With `USE_DNGSDK` off, LibRaw reads most DNGs too, but PixelLoupe's own reader is used for DNG so
  the spec path is one path.
- **Apple fallback** (exists): files neither reader handles keep `CIRAWFilter`, recorded per photo.

### 1.2 Linear reference values

Linearization, black subtraction, rescale by white, clip (DNG spec Ch. 5, p. 99, with the recommendation to keep
negative values into noise reduction). Per-ISO black and white levels where the camera needs them (rawspeed's
`cameras.xml` has per-ISO `Sensor` entries; LibRaw gives one pair). Defective pixels (`FixBadPixels` opcodes, or a
median on outliers). Highlight reconstruction (clip to the white-balanced minimum, or reconstruct from the two
unclipped channels, as Lightroom's Highlights recovery assumes). New; a Metal compute kernel over the mosaic.

### 1.3 Demosaic

New, and the stage that decides detail quality. Metal compute kernels (not `CIKernel`: they need neighbourhoods and
multiple passes), one per sensor layout:

- **Bayer:** RCD (darktable's default since it "offers similar performance to PPG, but with better results") for
  the preview, with AMaZE or LMMSE as a quality option for export (RawTherapee's default; "by far the slowest" in
  darktable, and no OpenCL version exists anywhere, so it would be PixelLoupe's own port). Dual demosaic (RCD blended
  with VNG4 by a local-contrast threshold) is how both projects handle noisy flat areas.
- **X-Trans:** Markesteijn 1-pass for preview, 3-pass for export (darktable and RawTherapee defaults). Six of the 31
  bodies in Ted's library are X-Trans, 7,525 files.
- **LinearRaw** (ProRAW, DNG Converter linear DNGs, PixelLoupe merges): passthrough. **Monochrome** sensors:
  passthrough. Quad-Bayer, pixel shift, Foveon, sRAW/mRAW (Canon YCbCr) and Sony "YCC" pseudo-RAW: fallback to Apple.
- **Reduced-scale rendering** for the preview: 2×2 binning of each Bayer cell (3×3 of X-Trans) is a cheap
  "superpixel" demosaic at half size, which is all Develop's preview, thumbnails and Smart Previews need. Apple's
  `scaleFactor` renders 1/4-scale 26–45 MP files in 0.04–0.07 s; that's the bar.

Sources: [darktable demosaic manual](https://docs.darktable.org/usermanual/development/en/module-reference/processing-modules/demosaic/),
[RawPedia](https://rawpedia.pixls.us/demosaicing/), the OpenCL kernels in `darktable/data/kernels` (PPG, VNG, RCD,
Markesteijn exist; AMaZE and LMMSE don't). Both projects are GPL-3, so the algorithms are reimplemented from the
papers and the reference code is only read.

### 1.4 Colour: camera RGB → XYZ D50 → working space

The DNG colour model (spec Ch. 6, pp. 100–104), new:

- One, two or three calibration illuminants (A, D65, and 1.6's third "as shot" set), interpolated by inverse
  correlated colour temperature.
- `XYZtoCamera = AB · CC · CM`; with ForwardMatrix, `CameraToXYZ_D50 = FM · D · Inverse(AB · CC)` (white balance as a
  diagonal in camera space); without it, `Inverse(XYZtoCamera)` and linear Bradford adaptation to D50 (matrix from the
  [ICC](https://www.color.org/chadtag.xalter)).
- As Shot neutral → temperature and tint, iteratively, with Robertson's isotemperature lines (Wyszecki & Stiles p. 228,
  as in Adobe's `dng_temperature.cpp`; tint scale −3000). **This is what fixes RAW-234**: on a DNG with Adobe's
  matrices the numbers come out as Lightroom's, and on a native file they're on the same scale as Lightroom's whenever
  the matrices are the same ones.
- `ProfileHueSatMap` (HSV deltas over linear ProPhoto primaries, interpolated between the illuminants), then the
  pipeline's exposure and fill stages, then `ProfileLookTable`, then `ProfileToneCurve` (cubic spline), then
  `RGBTables`; `BaselineExposure` + `BaselineExposureOffset` set the zero of Exposure; `DefaultBlackRender`;
  `ProfileGainTableMap` multiplies linear camera RGB (ProRAW's local tone map, which RAW-85 could only reproduce by
  keeping Apple's engine; here it's a table lookup). The HDR encoding for `ProfileDynamicRange` profiles.
- **Working space:** linear ProPhoto (ROMM; primaries and D50 white in
  [ISO 22028-2 / ICC](https://color.org/chardata/rgb/ROMMRGB.pdf)), which is what Lightroom's Develop module uses
  ([Adobe](https://helpx.adobe.com/lightroom-classic/desktop/workspace/color-management.html)), handed to the existing
  pipeline in the `CIContext`'s working space. The `ColorLUT` cube is sRGB-indexed today and would gain a ProPhoto
  variant so Adobe's HSL and curve maths line up.

This stage is also **RAW-126 (DCP profiles) done properly**: a `.dcp` is this tag set in a little-endian TIFF IFD with
magic `0x4352`, and the user's own Adobe Standard, Camera Matching and third-party profiles (ColorChecker, Lumariver,
dcamprof) apply at the right place instead of as a cube over Apple's tone-mapped output.

### 1.5 Default look and tone

The part Adobe doesn't publish. Adobe Color is Adobe Standard (the camera's DCP) plus a look table in an `.xmp`
(`crs:CameraProfile="Adobe Standard"` + `crs:LookTable`), plus Camera Raw's own base tone curve and its Process Version
tone controls (PV6 since Camera Raw 15.4; [process versions](https://helpx.adobe.com/camera-raw/desktop/get-started/overview-and-setup/process-versions.html)).
PixelLoupe already imports the look tables. The base curve is fitted, as RAW-125 fitted tables: Lightroom exports of
photos at Adobe Standard with every slider at zero against the engine's output with the same DCP, a 1-D curve (and
a residual table if needed) fitted on the flat-area blocks. Then `LightroomScales` and the RAW-45 fidelity suite tune
the tone sliders against that base rather than Apple's.

### 1.6 Noise reduction and sharpening

New. Apple's engine does both inside the decode with per-camera, per-ISO defaults the file turns on (RAW-85 found
Apple's MakerNote is what enables them for ProRAW). The pipeline has `CIFilter.noiseReduction` (used for non-RAW and
Smart Previews) and `SharpenRenderer` (Lightroom's Amount/Radius/Detail/Masking). Needed: a profile-based denoiser on
the linear mosaic or the demosaiced image (a wavelet or non-local-means kernel with the Poisson-Gaussian model DNG's
`NoiseProfile` tag defines, `N(x) = sqrt(S·x + O)`, estimated per photo from flat regions when the file has no tag;
darktable's per-camera `noiseprofiles.json` is GPL and can't be copied), colour-noise suppression in chroma, and
moiré handling (LMMSE/dual demosaic). This is where "detailed areas" are won or lost, and the first fidelity gate
measures it.

### 1.7 Lens corrections

`LensCorrector` exists (LensFun profiles, manual, defringe). New: DNG `OpcodeList2/3` (WarpRectilinear and
WarpRectilinear2, FixVignetteRadial, GainMap; spec Ch. 7, pp. 105–122), which is how DNG Converter and ProRAW carry
corrections, and the **makers' built-in corrections** Apple applies today when `isLensCorrectionSupported`: Fujifilm's
RAF tables (geometric, vignetting, chromatic aberration; documented by ExifTool), Sony's, Canon's and Nikon's. Per
brand, not per camera, and Fujifilm first (every RAF in the library has one). Until a brand's tables are read, its
files fall back to LensFun with the panel saying so.

### 1.8 Integration

- `DevelopSource`: a `RawEngine` protocol with two implementations (PixelLoupe, Apple), chosen per photo by a
  **process version** in `PhotoAdjustments` (the `shadowsProcess` of RAW-230 is the precedent), with "Update to
  current process" in Develop and at import settings, and the Lightroom import choosing the new engine when the
  catalog photo names a DCP PixelLoupe has (RAW-113 decision 18).
- The demosaiced linear image is cached as a Metal texture per photo and scale, so white balance, exposure and every
  slider are a shader pass, not a re-decode (Apple re-decodes).
- **Thumbnails** render through the engine (ImageIO today), **Smart Previews** become a downsized linear DNG from the
  engine's own data (the RAW-121 white-balance table goes away, because white balance is a diagonal in camera space),
  **HDR and panorama merge** decode through it, **Export** already goes through `PhotoRenderer`.
- Tests: synthetic DNG fixtures as the project builds them now; CC0 samples from [raw.pixls.us](https://raw.pixls.us/)
  (1,033 cameras, 2,020 files) for decode coverage; Lightroom exports for fidelity (RAW-45), which only Ted can produce.

## 2. What gets harder, lost or rebuilt

1. **Camera coverage becomes PixelLoupe's problem.** Apple's list for OS 27 has 19 brands and about 800 models
   ([support.apple.com/127493](https://support.apple.com/en-us/127493)), added with OS point releases at no cost to the
   app, about 25 models between the OS 26 and OS 27 lists. LibRaw lists 1,284 but adds cameras only in major releases
   and public snapshots, about one a year and never in point releases: 0.20 (Jul 2020), 202101, 0.21 (Dec 2022),
   202403, 202502, 0.22 (Jan 2026) ([changelog](https://raw.githubusercontent.com/LibRaw/LibRaw/master/Changelog.txt)
   and darktable's release notes, which name the snapshots). Adobe ships
   cameras roughly monthly (eight Camera Raw releases in 2026). Keeping Apple as the fallback engine means no file
   stops opening, but a new camera can render on Apple's base for months, and its owner sees the old look.
2. **Nikon HE and HE\* can't be decoded by any open-source project** (intoPIX TicoRAW, "patented technology";
   LibRaw: "no estimated completion date"; rawspeed, RawTherapee and Rawler have none). Z 8, Z 9, Z 6III, Z f and Z 50II
   shooters who chose HE stay on Apple's engine (whether Apple decodes HE is not confirmed here; its list names the
   bodies but not the codec). Ted's Nikon Z bodies (Z 7, Z 6, Z fc) predate HE. Future proprietary codecs carry the
   same risk: CR3 took 29 months to reach a LibRaw release, Panasonic v8 over three years.
3. **Detail quality is the real bet.** Apple's RAW 8 and RAW 9 demosaic and denoise with Core ML on the Neural Engine;
   RCD plus a wavelet denoiser is 2010s technology. The target is Lightroom's base, not Apple's, and Adobe's own base
   demosaic is also classical (its ML paths, Enhance Details and Denoise, are separate commands). Still, a failed gate
   here (section 4, phase 0) is the no-go.
4. **Performance.** Apple decodes 22–45 MP at full size in 0.23–0.83 s and renders 1/4 scale in 0.03–0.07 s. The
   engine must demosaic at full size in that time on the GPU and hold the result (45 MP × 3 × Float16 = 270 MB at full
   size; a few MB at preview scale). It wins back the re-decode Apple does on every white-balance change (0.08–0.32 s)
   and the 4.5 s Smart Preview white-balance tables. Memory for the demosaiced cache replaces the cache Apple keeps
   internally; test with the large-catalog rule in `SKILLS.md`.
5. **Built-in lens corrections** (Fujifilm, Sony, Canon mirrorless, some Nikon) are lost until each brand's tables are
   read. LensFun covers most lenses meanwhile, less exactly than the camera's own data.
6. **Every edited photo would change** if the engine simply replaced Apple's: different baseline exposure, tone
   curve and colour. Hence the per-photo process version. It costs a second code path for as long as photos stay on
   Apple's engine (Lightroom has carried PV2003 to PV6 for 20 years), and macOS updates keep moving the Apple-rendered
   ones as they do today.
7. **Fidelity to Lightroom is not just the engine.** With Adobe's matrices from a DNG and the user's DCP, colour lines
   up; tone depends on fitting Adobe's unpublished base curve and on `LightroomScales`, and the RAW-45 suite has to be
   built to measure it. Imports set to Adobe Color need the Adobe Color look (already imported) on an Adobe Standard
   base the user has imported (RAW-126); without the user's DCPs, PixelLoupe's own matrices are a close approximation,
   not Adobe's.
8. **Licensing and provenance.** PixelLoupe is MIT. LibRaw is LGPL 2.1 or CDDL 1.0 (as a separate dynamic framework
   either works; its licence file ships with the app, as libjxl's does). rawspeed's `cameras.xml` is CC BY-SA 3.0, the
   same licence LensFun is already bundled under. Adobe's `.dcp` and look files are never shipped; the user imports
   their own. The Adobe DNG SDK's licence allows use, modification and distribution "for any purpose" with a
   commercial indemnity clause ([EULA](https://www.adobe.com/support/downloads/dng/dng_sdk_eula_mac.html)), and
   implementing the DNG specification is covered by Adobe's royalty-free patent licence. The open question is colour
   matrices for native files: the open-source convention (copying Adobe's D65 matrix out of a converted DNG) has no
   licence from Adobe; section 3 gives PixelLoupe's alternatives.
9. **Metadata stays on ImageIO**, with its gaps (maker notes barely exposed; Sony's full-size preview not listed).
   LibRaw's makernote parsing fills some of them, and the RAW-127 maker-note reader the rest.
10. **ProRAW's look** moves from Apple's implementation of its own DNG tags to PixelLoupe's implementation of the same
    public tags (gain map, tone curve, baseline exposure); iPhone Photos remains the reference and may differ slightly.
11. **Apple's future work is forgone**: RAW 9's ML demosaic, `isHighlightRecoveryEnabled`, the semantic mattes (unused;
    PixelLoupe has `SubjectMatteStore`).
12. **Smart Previews already written** (linear Rec. 2020 at Apple's defaults) render on the Apple path until rebuilt;
    the rebuild is the existing maintenance pass.

## 3. Supporting new cameras (maintenance)

What one camera is, in data: its codec and container layout, CFA pattern, active area and crop, black and white
levels (per ISO or mode where needed), colour matrices for two illuminants, As Shot neutral conventions, a baseline
exposure, default noise and sharpening, and any brand tables (look, lens, exposure bias). With Apple, all of this
arrives in an OS update and can't be touched. With the engine:

| Case | What PixelLoupe does | Cost |
|---|---|---|
| **New body, codec LibRaw already reads** (most releases: a new Sony, Canon or Fujifilm body reuses its predecessor's format) | 1. Get samples: owner's files or CC0 ones from raw.pixls.us, one per mode (bit depth, compression, crop). 2. Check LibRaw opens it; if the model isn't in `cameralist.cpp`/`colordata.cpp`, add an alias and matrix entry in PixelLoupe's own camera table (below) rather than wait. 3. Colour matrices (see sourcing). 4. Black/white/crop checks against the samples. 5. Baseline exposure: match the camera's JPEG brightness (the RAW-125 harness does this already). 6. A decode fixture and a test. 7. Ship as a **camera-data file update**, downloadable out of band (as Apple's `downloadResources` does), so support doesn't wait for an app release. | About a day; mostly measuring. |
| **New codec or container** (CR3 in 2018, Sony lossless 2021, Nikon HE 2021, Panasonic v8 2022, DNG 1.7 JPEG XL 2023) | Wait for LibRaw (or Rawler/rawspeed to port) and rebuild the xcframework; the camera renders on Apple's engine meanwhile. Reverse-engineering a codec is not realistic for this project. | Weeks (rebuild and verification) after the upstream release, which has taken 3 weeks (Sony lossless) to 3+ years (Panasonic v8) and may never come (HE). |
| **New brand table** (a maker's look tags, lens tables, exposure bias) | Per brand once: Fujifilm, Nikon, Canon, Sony are in the library; Panasonic, OM System, Pentax, Leica when samples exist. | Days per brand. |
| **LibRaw release** | Rebuild the xcframework with `Scripts/build-libraw.sh`, run the decode fixtures (every camera in the data table), update the licence notice. | Hours; a few times a year. |
| **Apple decoder change** (macOS update) | Nothing for engine-rendered photos. Photos still on Apple's engine move as they do today. | None. |

**Sourcing colour matrices**, best first:

1. **The user's own DNGs and DCPs.** A DNG from Adobe's converter carries ColorMatrix1/2, ForwardMatrix1/2 and the
   HueSatMaps for the camera; Adobe's embed policy allows them to be used for any DNG. Imported `.dcp` files
   (RAW-126) apply to the user's native files as the user's own data.
2. **Measured.** A ColorChecker (24 or SG) shot under daylight and tungsten gives both matrices and a HueSatMap by
   least squares; the RAW-128 fitting tool's lineage. Ted can do this for the 31 bodies in the library; owners of
   other cameras can contribute shots (not photos) under CC0. Clean provenance, a few hours per body.
3. **rawspeed's `cameras.xml`** (CC BY-SA 3.0; 964 make+model pairs with a D65 matrix) for a single-illuminant fallback,
   attributed as LensFun is. Rawler's TOMLs carry A and D65 matrices under the repo's LGPL 2.1, with no stated source.
4. **LibRaw's `adobe_coeff`** (D65; "All matrices are from Adobe DNG Converter unless otherwise noted") comes with the
   decoder anyway and is the last resort, as it is in darktable and RawTherapee.

The camera-data table itself is a JSON or plist in the app bundle (one entry per `UniqueCameraModel`, with the matrix
source recorded per entry), with a unit test that every entry loads and every fixture decodes, mirroring RAW-113
decision 17.

How the others do it, for calibration: darktable requires CC0 samples on raw.pixls.us for every mode, a noise profile
per ISO, and drops cameras without samples at the next major release; time from a rawspeed PR to a darktable release
ran about 1.5 months (Z 8) to 14 months (Z 9), and the whole project is volunteers. Adobe staffs it: a camera and its
Camera Matching profiles ship in the next monthly Camera Raw, with the free DNG Converter carrying the same support to
older software. Apple shipped the Canon 5D Mark IV and Fujifilm X-T2 in macOS 10.12.2 (13 Dec 2016), a few months
after their announcement, and that cadence still holds.

## 4. Scope and timeline

Calibration: the repository has 177 merged PRs since its first commit on 2026-10-12 (about 10 a day, agent-written,
Ted reviewing and merging); 74k lines of app Swift, 32k of tests. Engine work is slower than feature work: each stage
has a measurement loop, several need Lightroom exports only Ted can make, and Metal kernels are debugged by eye. The
estimates below assume that cadence and count PRs as the unit, with calendar time as the range.

| Phase | What | Gate | Size |
|---|---|---|---|
| **0. Prototype** (scratch code, like RAW-125) | DNG Converter copies of ~20 photos from the library (Nikon, Canon, Fujifilm X-Trans, Sony; daylight, tungsten, high ISO). Read the CFA DNG, RCD and Markesteijn in Metal, the DNG colour model with the embedded Adobe Standard profile, a fitted base curve. Compare with Lightroom exports (Adobe Standard, sliders at zero) and with Apple's rendering, ΔE00 as RAW-125 measured it, and time full-size and 1/4-scale renders. | **Go** if flat areas are within ΔE00 2 mean / 5 p95 of Lightroom, detailed areas are no worse than Apple's, and full-size demosaic + colour is under 0.5 s for 45 MP on the M4 Pro. **No-go** returns to option A with these numbers on record. | 1–2 weeks, 1 PR (the write-up). |
| **1. Engine on DNG** | `RawEngine` module: DNG reader (sections 1.1–1.2), demosaic kernels (1.3), colour model and DCP reading (1.4, closes RAW-126), base look (1.5), noise reduction and sharpening defaults (1.6), opcodes (1.7), process version plumbing, thumbnails, Smart Previews, merges and export on the engine (1.8), ProRAW through its own tags, tests with synthetic fixtures. DNG users (Lightroom converts, ProRAW, merges) get it first. | RAW-45 fidelity suite built and run on the DNG set; all existing tests pass; large-catalog scroll and slider timing unchanged. | 25–40 PRs, 4–6 weeks. |
| **2. Native files through LibRaw** | `Scripts/build-libraw.sh` and the xcframework, the XPC decode service, unpack → engine, the camera-data table for the 31 library models then LibRaw's list, matrix sourcing (DCP import, measured, rawspeed), maker-note reader (RAW-127, RAW-137's `RawExposureBias`), Fujifilm built-in lens tables, As Shot on Adobe's scale (RAW-234), Apple fallback per photo, decode run over all 26,300 library files. | Every library file decodes or falls back by rule; As Shot within 50 K of Lightroom's on the test set; fidelity suite on native files. | 15–25 PRs, 3–4 weeks. |
| **3. Fidelity and parity** | Base-curve and `LightroomScales` fits against the new base; Lightroom import choosing the engine and DCPs (decision 18); re-fit camera-matching profiles (RAW-128→135 unhold); Sony, Canon, Nikon lens tables; AMaZE/LMMSE export quality option; dual demosaic; noise model tuning; "Update to current process" UI; README and release notes. | Decision 8's bar from RAW-113: at least as close to the camera JPEG as Lightroom's Camera Matching, now measurable on the same base. | 20–30 PRs, 4+ weeks, then ongoing. |

**Total to parity plus Adobe-profile rendering: about 70–100 PRs over roughly 3 months**, with the first two weeks
deciding whether to continue. Running costs afterwards: LibRaw rebuilds a few times a year, about a day per new
camera on a known codec, days per new brand table, and the fallback path for codecs nobody has opened.

For contrast, the volunteer projects this reuses took years for each piece (rawspeed's Fujifilm compressed decoder
reached a darktable release 23 months after the X-Pro2; Panasonic v8 took over three years), which is why the plan buys the decoders rather than
writing them, implements only what the DNG specification and the demosaic papers already describe, and keeps Apple's
engine for everything else.

## Recommendation

1. **Run phase 0 now.** It needs Ted for two things: Adobe DNG Converter installed (free), and about 20 Lightroom
   exports (16-bit TIFF, ProPhoto or Display P3, Adobe Standard, all sliders at zero, and the same photos at Adobe
   Color) of the DNG copies. Everything else is scratch code in the session scratchpad, as the RAW-85 and RAW-125
   prototypes were.
2. **Decide the engine's input strategy as option E + C**: the engine reads DNG; LibRaw feeds it native files; Apple
   stays as the per-photo fallback engine and the rendering of everything already edited.
3. **Treat per-camera colour data as the long-lived asset**, with its provenance recorded per entry: user-imported
   DCPs and DNGs first, measured matrices for Ted's own bodies, rawspeed's CC BY-SA table as the fallback.
4. **Keep RAW-127→135 and RAW-234 on hold until phase 0 reports**; RAW-126 (DCP) and RAW-137 (Fujifilm push) fold into
   phases 1 and 2 rather than being built on Apple's engine first.
5. **Decisions for Ted** before phase 1: whether PixelLoupe ships any Adobe-derived matrix at all (the open-source
   convention) or only measured and CC BY-SA data; whether Apple's engine stays selectable per photo indefinitely
   (as Lightroom keeps old process versions) or is retired after a migration period; and whether the engine is a
   separate Swift package (`Packages/RawEngine`) so the fitting tools and tests share it without the app.

## Measurements

Apple's RAW engine on an M4 Pro, macOS 27.2, decoder version 8, Metal `CIContext` with a linear Rec. 2020 working
space, rendered to an RGBAh bitmap. "Full" is the first render (decode included); "re-render" sets a new
`neutralTemperature` and renders again at the same size.

| File | MP | Built-in lens profile | Open | Full | Re-render | 1/4 scale | 1/10 scale |
|---|---|---|---|---|---|---|---|
| Fujifilm X-T3 RAF (X-Trans IV) | 26.0 | yes | 0.14 s | 0.48 s | 0.14 s | 0.04 s | 0.04 s |
| Sony α7 IV ARW | 32.7 | no | 0.06 s | 0.39 s | 0.12 s | 0.05 s | 0.05 s |
| Nikon D850 NEF | 45.4 | no | 0.06 s | 0.83 s | 0.32 s | 0.06 s | 0.07 s |
| Canon 5D Mark III CR2 | 22.1 | no | 0.06 s | 0.23 s | 0.08 s | 0.03 s | 0.03 s |
| Fujifilm X-E5 RAF (X-Trans V) | 39.8 | yes | 0.04 s | 0.53 s | 0.21 s | 0.06 s | 0.06 s |

Ted's library (Spotlight, 2026-10-30): 31 camera models across Nikon (D750, D7000, D850, D810, Z 7, Z 6, Z fc), Fujifilm
(X-T1, X-T2, X-E3, X-T3, X-T10, X-Pro2, X-E5, X-T4, X100T, X-Pro1, X-H2, X-T30), Canon (5D Mark III, 5D Mark II, Rebel
XTi, EOS M), Sony (α6600, α7 IV, α7CR, α7C), Apple (iPhone 18 Pro Max ProRAW, iPhone 6) and two drones (DJI FC220,
Autel XB015); about 26,300 camera RAW files, no CR3, ORF, RW2 or PEF. Lightroom Classic 15.6 is installed with 395
Camera Matching folders and 1,500 Adobe Standard DCPs (4,418 `.dcp` files, 200 KB on average).

## Sources

The research notes behind this write-up, with a URL for every claim, are in the session scratchpad:
`research-oss-decoders.md` (LibRaw, rawspeed, raw.pixls.us, codec timelines, demosaic algorithms, Rawler) and
`research-adobe-apple.md` (DNG 1.7.1.0 by chapter and page, Camera Raw process versions and profiles, the `crs:` XMP
schema, Adobe's and Apple's camera-support cadence, `CIRAWFilter`'s API, WWDC21 10160 and WWDC26 305, the colour
standards and the DNG SDK licence), with the downloaded primary sources beside them. The benchmark is
`bench/main.swift` there. Key primary sources:

- [DNG Specification 1.7.1.0](https://helpx.adobe.com/content/dam/help/en/photoshop/pdf/DNG_Spec_1_7_1_0.pdf) (Ch. 5–7)
  and the [DNG SDK](https://helpx.adobe.com/camera-raw/desktop/dng-and-file-formats/digital-negative.html) 1.7.1 build 2768.
- [Camera Raw process versions](https://helpx.adobe.com/camera-raw/desktop/get-started/overview-and-setup/process-versions.html),
  [profiles](https://helpx.adobe.com/camera-raw/desktop/edit-and-enhance-images/tone-and-color/adjust-color-rendering-camera-camera.html),
  [supported cameras](https://helpx.adobe.com/camera-raw/desktop/dng-and-file-formats/camera-raw-plug-supported-cameras.html).
- [`CIRAWFilter`](https://developer.apple.com/documentation/coreimage/cirawfilter), Apple's
  [OS 27 RAW list](https://support.apple.com/en-us/127493), [WWDC26 305](https://developer.apple.com/videos/play/wwdc2026/305/).
- [LibRaw](https://www.libraw.org/) ([changelog](https://raw.githubusercontent.com/LibRaw/LibRaw/master/Changelog.txt),
  [COPYRIGHT](https://raw.githubusercontent.com/LibRaw/LibRaw/master/COPYRIGHT)), [rawspeed](https://github.com/darktable-org/rawspeed)
  (`cameras.xml`), [raw.pixls.us](https://raw.pixls.us/), [Rawler](https://github.com/dnglab/dnglab),
  [darktable demosaic](https://docs.darktable.org/usermanual/development/en/module-reference/processing-modules/demosaic/),
  [RawPedia demosaicing](https://rawpedia.pixls.us/demosaicing/).
