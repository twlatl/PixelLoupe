# PixelLoupe's RAW Engine

**Short answer:** PixelLoupe still uses Apple's engine. Every RAW file is decoded by `CIRAWFilter` from Core Image
(the engine macOS calls "RAW 9" on macOS 27). The Lightroom catalog and preset work didn't replace it. That work added
a layer that translates Adobe's settings and profiles into PixelLoupe's own adjustments, which then run through the
same Core Image pipeline. No Adobe code (DNG SDK, ACR) and no third-party decoder (LibRaw, dcraw) is in the project.

## 1. Decode: `DevelopSource`

[DevelopSource.swift](PixelLoupe/Develop/DevelopSource.swift) is the one entry point. The Develop preview, thumbnails
([ThumbnailStore.swift](PixelLoupe/Thumbnails/ThumbnailStore.swift)), export
([PhotoExporter.swift](PixelLoupe/Export/PhotoExporter.swift)), the loupe and the JPEG writer
([PhotoRenderer.swift](PixelLoupe/Develop/PhotoRenderer.swift)) all create a `DevelopSource`, so they always match.

- **RAW files** open as `CIRAWFilter(imageURL:)`. The camera's defaults are recorded at open time: as-shot temperature
  and tint, noise reduction, sharpness, detail, and whether the file's built-in lens profile is on.
- **Other files** (JPEG, HEIC, TIFF…) open as a plain `CIImage`, downscaled with Lanczos and cached per scale.

Some settings are applied inside the RAW engine, at demosaic time, because the quality is better there
(`DevelopSource.baseImage(with:scale:)`):

| PixelLoupe setting | Engine parameter |
|---|---|
| Render size | `scaleFactor`: previews decode at display resolution, not full size |
| Exposure | `exposure` |
| White balance | `neutralTemperature` / `neutralTint` |
| Noise reduction (luminance and color) | `luminanceNoiseReductionAmount`, `colorNoiseReductionAmount` |
| Sharpening | The engine's `sharpnessAmount` and `detailAmount` are set to 0 whenever PixelLoupe's own Sharpen is active, so the photo isn't sharpened twice |
| Built-in lens profile | `isLensCorrectionEnabled` (for formats that embed one, mostly mirrorless) |

For non-RAW files, Core Image filters stand in for these: `exposureAdjust`, `temperatureAndTint` and `noiseReduction`.

## 2. Geometry before the pipeline

`DevelopSource.image(with:scale:)` then applies, in order:

1. **Lens corrections** ([LensCorrector.swift](PixelLoupe/Develop/Lens/LensCorrector.swift)): LensFun profiles bundled
   in `Resources/LensFun`, applied with custom Metal kernels in
   [LensKernels.swift](PixelLoupe/Develop/Lens/LensKernels.swift). Vignetting comes first, then distortion and lateral
   chromatic aberration in one resample, then defringe. A LensFun profile is skipped when the camera's built-in
   profile is already applied.
2. **Rotate/flip.**
3. **Perspective transform** ([TransformRenderer.swift](PixelLoupe/Develop/Lens/TransformRenderer.swift)).

## 3. The shared pipeline: `AdjustmentPipeline`

The rest runs in a fixed order (`AdjustmentPipeline` in [DevelopSource.swift](PixelLoupe/Develop/DevelopSource.swift)),
all as lazy `CIImage` graphs on the GPU:

1. **Adobe profile hidden settings are merged in** (`AdobeProfileLook`). Some Adobe profiles carry their own sliders,
   curves and color grading, and these are added at the profile's Amount.
2. Spot removal and red-eye ([RetouchRenderer.swift](PixelLoupe/Develop/Retouch/RetouchRenderer.swift)).
3. Highlights, shadows and brilliance (`CIHighlightShadowAdjust`).
4. **The Adobe profile's look**: its tables baked into color cubes.
5. **One combined 3D LUT** ([ColorLUT.swift](PixelLoupe/Develop/ColorLUT.swift)): the tone curve from the Light
   sliders, Levels, Curves, color-grading wheels, Selective Color (HSL), Black & White, vibrance/saturation and camera
   calibration, all folded into a single 33³ cube. It's rebuilt only when one of those settings changes. This
   one-lookup-per-pixel design is what keeps slider drags smooth.
6. Texture, Clarity and Dehaze ([PresenceRenderer.swift](PixelLoupe/Develop/PresenceRenderer.swift)), then Definition.
7. Sharpening ([DetailRenderers.swift](PixelLoupe/Develop/DetailRenderers.swift)), with radius, detail and masking.
8. Masks and local adjustments
   ([LocalAdjustmentRenderer.swift](PixelLoupe/Develop/Masking/LocalAdjustmentRenderer.swift)).
9. Straighten and crop.
10. Post-crop vignette, then grain (seeded noise with an Overlay blend).

The output goes to a shared `CIContext`: Display P3 for on-screen rendering, sRGB for JPEG export.

## 4. What the Lightroom work added

All of it feeds into the pipeline above.

- **Catalog import** (`PixelLoupe/LightroomImport/`) reads the `.lrcat` SQLite database and parses each photo's
  `Adobe_imageDevelopSettings` (a Lua table).
  [LightroomDevelopMapper.swift](PixelLoupe/LightroomImport/LightroomDevelopMapper.swift) converts those settings into
  `PhotoAdjustments`, including converting older Lightroom process versions.
  - Anything that can't be matched exactly is recorded as a `Difference`. Examples: Auto white balance comes in as As
    Shot; Adobe Color/Standard comes in as PixelLoupe's Default ("close but not identical"); Upright, HDR/glow, point
    color and lens blur aren't imported.
  - [LightroomDevelopCoverage.swift](PixelLoupe/LightroomImport/LightroomDevelopCoverage.swift) lists every Lightroom
    key as mapped, bookkeeping, legacy or unsupported.
- **Presets** ([DevelopPreset.swift](PixelLoupe/Presets/DevelopPreset.swift),
  [LegacyPreset.swift](PixelLoupe/Presets/LegacyPreset.swift)): `.xmp` presets and older `.lrtemplate` files go through
  the same mapper. Applying one changes only the settings it contains, including ISO-dependent ones.
- **Adobe profiles** ([AdobeProfile.swift](PixelLoupe/Presets/AdobeProfile.swift)): profile `.xmp` files (Adobe Color,
  B&W, the creative looks, camera-matching profiles) are parsed for their DNG "big tables", meaning the HSV look table
  and/or the RGB table. These are baked into Core Image color cubes.
  - These cubes are applied to the image *after* Apple has decoded it. That's an approximation: Adobe applies these
    tables inside its own colorimetric pipeline. So an imported photo can look close to Lightroom but not
    pixel-identical.
- **Thumbnails** can be seeded from Lightroom's own previews so a big import shows images right away. They're tracked
  in [SeededThumbnails.swift](PixelLoupe/Thumbnails/SeededThumbnails.swift) and later redrawn by PixelLoupe's renderer
  for photos that have edits.

## 5. Photo Merge ▸ HDR (RAW-74)

[HDRMerger.swift](PixelLoupe/Merge/HDRMerger.swift) uses `CIRAWFilter` as well. Each bracketed exposure is decoded
linearly (no tone curve, shadow bias or baseline exposure), and the frames are merged with exposure weighting,
Vision-based alignment and optional deghosting. The merged frame is in linear Rec. 2020.
[LinearDNGWriter.swift](PixelLoupe/Merge/LinearDNGWriter.swift) saves it as a linear DNG, which re-enters the normal
pipeline through `CIRAWFilter`.

## What this means in practice

Demosaicing, camera color matrices and the base rendering come from Apple and change with macOS updates. Lightroom
fidelity is limited by how well Adobe's settings and profile tables can be reproduced on top of Apple's decode. It
doesn't come from running Adobe's engine.
