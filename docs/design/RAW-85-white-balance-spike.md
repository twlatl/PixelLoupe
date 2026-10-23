# RAW-85 spike: white balance on Smart Previews

**Question:** can Temperature and Tint on a Smart Preview render the way they do on the original, and what would it
cost? See [the design](RAW-85-smart-previews.md), section "White balance far from As Shot".

**Answer:** mostly, with one number per setting. The drift is mainly a brightness error, and an exposure offset from
a small per-camera or per-photo table removes most of it:

- **3000–3500 K:** ΔE00 from 8–14 down to about 1.5–4.
- **4500 K / −15 and 10000 K:** from 4–5 down to about 1.5–3.

Color matrices applied through `CIRAWFilter.linearSpaceFilter` are worse than the exposure offset at the warm end and
only slightly better at the cool end, so they aren't worth it.

Separately, **iPhone ProRAW originals don't work with the current recipe at all**, even at As Shot (ΔE00 7–19). That
needs its own approach, below.

## Method

Float16 proxies were used throughout, so compression plays no part. They follow the design's recipe (linear Rec. 2020,
neutral at D65, `AsShotNeutral` set to the original's, `BaselineExposure` carrying the headroom), rendered with the
original's `shadowBias` and `localToneMapAmount`.

- **The original** was rendered at 2560 px as `DevelopSource` would, with sharpening off to compare color.
- **The comparison** is ΔE2000 mean / p95 over every second pixel each way (CIELAB, D65).
- **Calibration decodes** are the RAW engine's linear output (no baseline exposure, boost, shadow bias, local tone map
  or gamut mapping) at scale 0.05, from one reused `CIRAWFilter`.

Photos:

- three frames of the RAW-95 panorama samples (Sony, 61 MP ARW): `DSC00245`, `DSC00250` and `DSC00256`, with As Shot
  between 5080 and 5480 K;
- one iPhone 18 Pro Max ProRAW DNG (48 MP), used only for local measurements.

The prototype is `wb/main.swift` in the session scratchpad (with `dng.swift`), not committed.

## Results (Sony)

### Corrections fitted at each setting, `DSC00245`

| Setting | Plain proxy | Exposure offset (anchored at As Shot) | Full 3×3 via hook (at D65) | Residual 3×3 via hook |
|---|---|---|---|---|
| As Shot (5194 K / +12) | 1.93 / 3.08 | 1.93 / 3.08 (0 EV) | 3.03 / 5.01 | 1.93 / 3.08 |
| 3000 K / 0 | 12.09 / 17.95 | **3.41** / 6.31 (−1.25 EV) | 5.09 / 11.46 | 5.28 / 9.18 |
| 3500 K / 0 | 8.40 / 12.97 | **1.70** / 2.86 (−0.78 EV) | 4.47 / 9.14 | 2.40 / 5.63 |
| 4500 K / −15 | 4.03 / 6.55 | **1.62** / 2.55 (−0.23 EV) | 3.35 / 5.92 | 1.73 / 2.93 |
| 7500 K / +20 | **1.91** / 3.29 | 2.60 / 3.90 (+0.18 EV) | 2.82 / 4.40 | 2.48 / 3.59 |
| 10000 K / 0 | 4.06 / 6.69 | 2.97 / 4.85 (−0.10 EV) | 3.46 / 5.41 | **2.49** / 4.47 |

### From a table, and from another photo's table

The table has 8 temperatures (2500–12000 K, interpolated in mired) × 3 tints (−30, 0, +30) and stores 24 numbers
(96 bytes).

| Setting | `DSC00250` plain | own table | `DSC00245`'s table | `DSC00256` plain | own table | `DSC00245`'s table |
|---|---|---|---|---|---|---|
| As Shot | 1.62 | 1.62 | 1.62 | 2.85 | 2.85 | 2.85 |
| 3000 K / 0 | 13.94 | **1.57** | 3.48 | 14.07 | 4.01 | **2.90** |
| 3500 K / 0 | 10.21 | 1.80 | **1.49** | 10.23 | 3.63 | **1.42** |
| 4500 K / −15 | 5.04 | 1.71 | **1.20** | 5.03 | 2.79 | **2.48** |
| 7500 K / +20 | **0.90** | 1.40 | 1.79 | **0.93** | 2.06 | 3.04 |
| 10000 K / 0 | 4.16 | **2.28** | 2.51 | 4.17 | **2.66** | 3.63 |

(ΔE00 means; p95s are in the run logs.)

## Findings

1. **Most of the drift is brightness, and an exposure offset fixes most of it.** With plain Temperature/Tint, a proxy
   at 3000 K is 13–15 L* too bright, and at 3500 K 9–11 L*. The offset is applied through `CIRAWFilter.exposure`.
   It's measured on the engine's linear output as the least-squares luminance gain between the proxy at (T, tint) and
   the original's white-balance change applied to the proxy's pixels. It has to be **anchored at As Shot**: the
   applied offset is `table(T, tint) − table(As Shot)`. Without the anchor, every correction came out about 0.25 EV
   too dark, even at As Shot, where the plain proxy is already right.
2. **Color matrices don't add enough.** A per-setting 3×3 applied through `linearSpaceFilter` beat the exposure offset
   only at the cool end, by at most 0.5 ΔE00, and was much worse at the warm end (3000 K: 5.3 against 3.4). Two
   reasons:
   - the engine does something white-balance-dependent after that stage (a perfect proxy-to-proxy matrix still landed
     ΔE00 1.9 from the engine's own As Shot);
   - the hook works in the CIContext's **working space** (Develop uses Display P3, `PhotoRenderer.context` sRGB), so
     a Rec. 2020 matrix must be converted per context.
3. **A table interpolates well.** 8 × 3 points in mired and tint matched the exact per-setting result within
   0.2–0.4 ΔE00.
4. **One table per camera model is a fair approximation.** The offset depends on scene content as well as the camera:
   at 3000 K, `DSC00245`, `DSC00250` and `DSC00256` needed −1.25, −0.99 and −0.76 EV. A table from one frame still took the other two from
   ΔE00 14 to 2.9–3.5 at 3000 K, and was sometimes better than their own tables.
5. **Building a table is the slow part.** The RAW engine redoes its decode for every white balance, even at scale 0.05
   with one reused filter: 0.2–0.3 s per point, 4.5 s for the 24-point table on a 61 MP ARW. That's about 5× the rest of a Smart
   Preview's build (0.5 s decode + 0.3 s encode). Once per camera model is negligible.
6. **The correction slightly hurts settings near As Shot on the cool side.** 7500 K / +20 went from 0.9–1.9 to
   1.4–3.0. The plain proxy is already good there and the estimate overshoots small offsets. A log-average gain was
   tried instead; it was better on some frames and worse on others. Fading the offset in only beyond some distance
   from As Shot is the obvious next tweak, but it wasn't tested.
7. **Make and Model in the proxy don't matter.** A proxy with the camera's names and one with made-up names render
   identically (ΔE00 0.00), which closes that caveat in the design.
8. **The As Shot floor varies by photo:** ΔE00 1.6–2.9 across the three frames, from the engine rendering a Linear DNG
   differently from the camera file.

## ProRAW doesn't work with this recipe

*Followed up in the [ProRAW spike](RAW-85-proraw-spike.md): a downsized copy of the original DNG, keeping its own
profile and gain map, matches the original within ΔE00 0.3–0.7.*

iPhone ProRAW is already a demosaiced (LinearRaw) DNG. It carries rendering data that a Rec. 2020 proxy loses:
`ProfileToneCurve` (257 points), `ProfileGainTableMap` (DNG 1.6 local tone mapping; the engine defaults
`localToneMapAmount` to 1.0 for it), `DefaultBlackRender`, a +5.35 EV `BaselineExposure`, and dual color matrices.

| Proxy for the ProRAW DNG | ΔE00 at As Shot (mean / p95) |
|---|---|
| As designed | 18.7 / 28.0 (ΔL +23) |
| Without the original's `shadowBias` / `localToneMapAmount` | 20.0 / 36.5 |
| Tone curve and black render copied, local tone mapping baked into the pixels | 8.7 / 14.2 |
| … baked with the baseline exposure applied | 6.9 / 9.4 |
| Local tone mapping off on both sides (to isolate white balance) | 6.6 / 9.5 |

- **The gain map can't be copied:** no proxy carrying `ProfileGainTableMap` opens in `CIRAWFilter`, whether it
  declares DNG 1.4, 1.6 or 1.7, with float or integer samples.
- **White balance can't be judged on ProRAW** while As Shot is this far off. The plain proxy matched at 7500 K
  (ΔE00 0.7) but not at As Shot.
- **A better route for ProRAW**, and any other LinearRaw DNG (including PixelLoupe's own merges): make the proxy a copy
  of the original DNG with only its main image downsized and recompressed, keeping all of its own tags. The data is
  already linear, so downsizing is legitimate, and the camera's own matrices would keep white balance exact.
  - Reading the original's samples needs a lossless JPEG (compression 7) decoder, about 200 lines; Apple's APIs don't
    expose them.
  - It's unknown whether the engine accepts a gain map there when the rest of the original's structure is kept.

## Recommendation

*Decided 2026-10-19: the per-camera-model exposure correction ships in v1 (delivery PR 6 in the design).*

- **Camera RAW files (ARW and the like):** add the exposure correction from a **per-camera-model table**. Build it from
  the first Smart Preview of each camera model, at about 4.5 s once. Keep it in the catalog (about 100 bytes per model,
  for example `Smart Previews/White Balance/<Make Model>.json`, or in each proxy's `DNGPrivateData` if per-photo tables
  are chosen later). At render time it's one interpolation and an `exposure` change in the proxy path of
  `DevelopSource.baseImage`. This takes the worst case (tungsten on a daylight photo) from ΔE00 about 14 to about 3,
  for almost no build cost. Per-photo tables were better on one frame and worse on the other, and add about 4.5 s
  to every build, so they wait for evidence from more cameras.
- **Leave chroma alone.** Matrices through `linearSpaceFilter` don't pay off.
- **ProRAW and other LinearRaw DNGs:** superseded. The [ProRAW spike](RAW-85-proraw-spike.md) found the
  downsized-copy recipe, which ships in v1 with JPEG XL tiles and needs no white-balance correction.
- **Before shipping the correction:** measure at least two more camera makers (for example Canon CR3 and Fujifilm RAF,
  which use built-in lens profiles too), and try fading the offset in only away from As Shot (finding 6).
