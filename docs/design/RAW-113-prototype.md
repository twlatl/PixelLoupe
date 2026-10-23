# RAW-113 prototype: fitting Classic Chrome

**Question (RAW-125):** can PixelLoupe match a camera's own look by fitting a color table from PixelLoupe's Default
render to the camera's JPEG of the same photo, well enough to build camera-matching profiles on it? See
[the design](RAW-113-color-profiles.md), decisions 3, 7, 8 and 14, and its "Left to the prototype" questions.

**Answer: the fallback bar is met but decision 8's isn't, and the build is on hold.** One 17³ table, fitted on 460 X-T1 photos, takes held-out
photos from ΔE00 9.5 mean / 18.3 p95 (Default as it renders today) to **1.15 / 2.98**, and holds on bodies it never
saw: X-T10 1.43 / 2.55, X100T 1.16 / 3.33 and X-E3 (the next sensor generation) 1.78 / 3.17. That clears the fallback
bar (mean ≤ 3, p95 ≤ 6) everywhere. Skies, foliage and skin match side by side.

**Against Lightroom (decision 8), the bar isn't met.** Three X-T3 photos can be compared with the camera's JPEG (one
Provia, two Velvia), and Lightroom's Camera Matching profile is closer on all three. The mean is close on two of them
(1.28 against 1.26, 1.74 against 1.56). Lightroom is clearly ahead at ISO 3200 (1.13 against 0.79) and on p95 for all
three (2.4–4.3 against 2.1–2.9). That's after correcting two things in the prototype's own scoring that favored
Lightroom. In flat areas the colors match. The gap is in detailed areas, where Apple's base differs from the camera's,
and in one stage-lit color the training never covered.
All three are within the fallback bar. See [Against Lightroom](#against-lightrooms-camera-matching-profiles).

**Ted's decision (2026-10-20): hold the build.** The tickets that build on this (RAW-127 to RAW-135) are labelled
`on-hold`. Later, Ted will look into a platform-independent RAW parser to replace Apple's RAW engine. Most of the
remaining gap to Lightroom is in Apple's base, which no table can change. Every table here was fitted to that base, so
a new engine means new fits, though the method carries over ([Recommendation](#recommendation)).

It takes one change that isn't a table: **the base has to be normalized before the profile**. Apple's RAW engine
renders each Fujifilm body at its own brightness (a baseline exposure of −0.70 EV for the X-T1, +0.02 to +0.22 for the
others) and ignores the push the camera records for high ISOs. A camera-matching profile therefore sets the RAW
engine's exposure to cancel both, adding to the photo's own Exposure. With that, one table per look per brand works
(decision 7), and the brightness is part of the look.

**Velvia,** the harder (saturated) look and the one with pairs from all four sensor generations, shows the limit: a
table fitted on one generation does about as well on the others as on its own, and in daylight it's within or near the
bar on every body (held out: 1.5–3.0 / 3.6–6.7). Under warm indoor light (As Shot under 3800 K) the camera renders
differently, and one table for all light falls to about 3.9 mean. A second table for warm light, blended by the
photo's white balance as DNG profiles do with their two illuminants, recovers part of that. Classic Chrome, a muted
look, stays within the bar under warm light with one table (2.2).

## Method

- **Pairs:** Fujifilm RAF files with a same-name JPEG, found from the RAW-113 survey and sorted by the maker notes
  (FilmMode `0x1401`; Color `0x1003`, Highlight and Shadow tone `0x1041`/`0x1040`, D-Range `0x1402`/`0x1403`, Grain,
  Color Chrome). Only photos shot at Color 0, Highlight and Shadow 0 and D-Range 100% count.
  - Classic Chrome: 571 X-T1 photos after removing copies of the same photo in two folders (1,229 files; one trip,
    2015-05-28 to 06-06), and 54 from other bodies: X-T10 (23), X-E3 (27), X100T (4).
  - All 65 X-E5 Classic Chrome pairs were shot with Color +2, Highlight and Shadow −1, Color Chrome Effect and Grain,
    so the X-E5 (X-Trans V) was tested with Velvia instead, which has neutral pairs from all four sensor generations.
  - Every pair passed the check against the RAF's embedded preview (under 2/255 apart), so all are genuine camera
    JPEGs; size and the camera's firmware in Software matched too.
- **Default:** `CIRAWFilter` at its own defaults, as `DevelopSource.baseImage` uses it with default adjustments, with
  sharpening off. The settings that could vary its output by photo don't on Fujifilm: local tone mapping 0, shadow
  bias 3, boost 1, shadow boost 0.9 on every photo of every body.
- **Rendering for the fit:** both images at 1536 px, the camera JPEG registered to the render (a scale about the
  centre, a radial term and a shift, by gradient correlation; see finding 8), then averaged in 8 × 8 blocks in linear
  light to 192 × 128. Each block is a sample. Color is fitted and scored on these blocks, where sharpening, noise
  reduction and grain average out; Lightroom's exports are registered and reduced the same way.
- **Score:** ΔE2000 (CIELAB, D65) over every block of every held-out photo: the pooled mean and p95. Per class
  (from the camera JPEG's color): sky (blue, upper 60% of the frame), foliage (yellow-green to green), skin-like tones.
- **Held out:** photos are grouped into shooting sessions (a 20-minute gap starts a new one) and every fifth session
  is held out, so no scene is on both sides: 63 X-T1 photos. Since they all come from one trip, the other bodies (2015,
  2016, 2022) are the more independent test.
- **The table:** a 3D table on the sRGB-encoded cube (input clipped as Core Image's cube does), trilinear, fitted by
  least squares over all blocks with a penalty on its second derivatives (so the fit continues smoothly where photos
  have no samples), solved coarse to fine (9³, then 17³).

The prototype is `raw125/` in the session scratchpad, not committed; its source, a README and the held-out lists are
in the RAW-113 session notes folder (`RAW-125-prototype/`).

## Results: Classic Chrome

Fitted on 460 X-T1 photos (ISO ≤ 2000) with the normalized base, 17³, sRGB. ΔE00 mean / p95:

| Held-out photos | Photos | Default today¹ | Normalized base | **+ table** | Sky | Foliage | Skin |
|---|---|---|---|---|---|---|---|
| X-T1 (X-Trans II), ISO ≤ 2000 | 43 | 9.47 / 18.30 | 4.06 / 8.45 | **1.15 / 2.98** | 0.85 / 1.88 | 1.29 / 2.77 | 1.41 / 3.15 |
| X-T1, ISO 2500–6400 | 20 | 22.28 / 43.79 | 5.07 / 10.57 | **2.06 / 4.31** | 1.68 / 3.29 | 1.97 / 4.22 | 2.15 / 3.95 |
| X-T10 (X-Trans II) | 20 | 6.57 / 10.60 | 5.94 / 9.50 | **1.43 / 2.55** | 1.91 / 2.96 | (few) | 1.59 / 3.54 |
| X100T (X-Trans II) | 4 | 5.74 / 17.11 | 3.44 / 6.68 | **1.16 / 3.33** | (few) | (few) | 1.95 / 4.78 |
| X-E3 (X-Trans III) | 27 | 3.21 / 6.01 | 3.25 / 6.02 | **1.78 / 3.17** | 1.80 / 3.00 | 2.32 / 3.67 | 2.55 / 4.46 |

¹ Scored before registration was added; for these bodies registration moves the scores by at most 0.03.

**On Default as it is,** a table fitted the same way matches the X-T1 (1.23 / 3.43) but bakes in the X-T1's
brightness: it renders the X-E3 and X-T10 12 L* too bright (10.2 / 16.5 and 10.8 / 16.3).

Fitting on the high-ISO photos too (508 photos, all ISOs) gives 1.41 / 3.48 over all 63 held-out X-T1 photos and
changes the other bodies by less than 0.1.

### Method choices

On the held-out X-T1 photos (ISO ≤ 2000) unless noted, before registration; ΔE00 mean / p95.

| Choice | Result |
|---|---|
| Table size (λ 1e-6) | 9³ 1.39 / 3.53, 17³ 1.34 / 3.48, 33³ 1.31 / 3.47, 49³ 1.30 / 3.46 |
| Cube space (33³) | sRGB 1.31 / 3.47, Display P3 1.32 / 3.49, ProPhoto 1.36 / 3.53 |
| Smoothing λ (33³) | 1e-1 3.49, 1e-2 3.24, 1e-3 1.86, 1e-4 1.55, 1e-5 1.38, **1e-6 1.31**, 1e-7 1.29 (rough, see finding 4) |
| Edge blocks down-weighted | 1.31 / 3.47; weighted equally 1.18 / 3.15 |
| Target | camera JPEG 1.18 / 3.15; the RAF's embedded preview 1.15 / 3.18 |
| Exposure fitted per photo | 1.09 / 2.88 against 1.15 / 2.98 (registered); per-photo offsets sd 0.06 EV |

## Results: Velvia across sensor generations

Velvia is the harder look (strong saturation) and the one with neutral pairs from all four sensor generations: 803
photos, X-T1 (179), X-T2 (118), X-E3 (113), X-T3 (298), X-T4 (74), X-E5 (21, one session). Same method, all ISOs.
ΔE00 mean / p95 over each body's photos (held-out sessions only for the body a table was fitted on):

| Body (sensor) | Normalized base | Table fitted on X-T1 | Table fitted on X-T3 | Pooled table, held out |
|---|---|---|---|---|
| X-T1 (II) | 5.07 / 10.72 | 2.87 / 8.00 (held out) | 3.59 / 9.94 | 2.98 / 8.25 |
| X-T2 (III) | 4.87 / 12.31 | 3.09 / 10.10 | 3.03 / 10.50 | 1.62 / 3.44 |
| X-E3 (III) | 2.81 / 5.55 | 2.18 / 4.71 | 1.69 / 3.77 | 2.25 / 4.27 |
| X-T3 (IV) | 3.91 / 8.92 | 2.36 / 6.74 | 1.97 / 5.47 (held out) | 1.54 / 5.59 |
| X-T4 (IV) | 4.84 / 9.31 | 2.85 / 6.26 | 2.96 / 7.09 | 3.01 / 6.68 |
| X-E5 (V) | 5.31 / 11.72 | 3.56 / 8.94 | 3.63 / 9.45 | (no held-out session) |

(Default as it renders today is further off still, by the brightness differences in finding 1.)

**By the light (pooled table, held-out photos):**

| Body | Under 3800 K | 3800–4800 K | 4800–6000 K | Over 6000 K |
|---|---|---|---|---|
| X-T1 | 3.92 (18 photos) | 1.78 (14) | | |
| X-T3 | 2.25 (5) | 1.93 (8) | 1.43 (69) | 1.58 (65) |
| X-E3 | | | 2.25 (94) | 2.26 (4) |

Fitted and scored on daylight photos only (As Shot from 3800 K), the pooled table gives X-T1 1.77 / 4.21, X-T2
1.64 / 3.58, X-E3 2.22 / 4.21, X-T3 1.46 / 5.30 and X-T4 3.01 / 6.71. On the X-T1, a table fitted only on its warm-light
photos (38) scores 3.10 / 6.98 on the warm held-out ones, against 3.85 for one table for all light; a daylight-only
table scores 1.48 / 3.64 in daylight, against 1.62.

A Display P3 cube made no difference for Velvia either (pooled: within 0.05 everywhere).

## Against Lightroom's Camera Matching profiles

Ted exported X-T3 photos from Lightroom Classic 15.6, with everything but the profile at Lightroom's defaults
(`Design/Fuji Examples/`, untracked). Each export records its profile in its XMP (`crs:CameraProfile`), not its EXIF.

- **DSCF3168** (2018-10-20, overcast outdoors: foliage, hay, a red shirt, no blue sky) with each of the 15 Camera
  Matching profiles Lightroom offers for the X-T3. Its camera JPEG is Provia.
- **DSCF3669** (2018-11-24, outdoors by day, ISO 800) and **DSCF3523** (2018-11-09, an evening photo at ISO 3200) with
  "Camera Velvia/VIVID v2". Their camera JPEGs are Velvia.
- **DSCF3632** (2018-11-23) with Velvia too, but its camera JPEG is black and white, so it can't be compared.

That makes three photos where Lightroom, a fitted table and the camera can all be compared. The tables never saw those
days. The Provia table is fitted on 182 photos from the X-T2 (92), X-Pro1 (60), X-E3 (19), X-Pro2, X-T4, X-T30 and a
single X-T3; that's the library's only X-T3 Provia photo at D-Range 100%, and the other nine are at 200%. The Velvia
table is the X-T3's, refitted without the three days (74 photos, all ISOs); the pooled Velvia table did worse on both
photos. Lightroom's profiles are made for each camera model.

**Against the camera's JPEG** (ΔE00 mean / p95):

| Photo | Default today | Table, scored as above | Table¹ | Lightroom¹ |
|---|---|---|---|---|
| DSCF3168, Provia | 2.20 / 3.92 | 1.43 / 2.81 | 1.28 / 2.41 | **1.26 / 2.11** |
| DSCF3669, Velvia | 3.62 / 6.76 | 2.31 / 5.79 | 1.74 / 3.79 | **1.56 / 2.87** |
| DSCF3523, Velvia, ISO 3200 | 4.11 / 9.32 | 1.27 / 5.46 | 1.13 / 4.26 | **0.79 / 2.34** |

¹ Measured more fairly than the rest of this write-up: the table applied to every pixel before the blocks are
averaged, and each JPEG aligned to the render tile by tile as well as globally (see below). Scored as above,
Lightroom is 1.32 / 2.37, 1.60 / 3.07 and 0.85 / 2.65.

**By detail** (table¹ / Lightroom¹, mean and p95; blocks sorted by the camera JPEG's texture within the block):

| Photo | Flat | Some detail | Edges and detail |
|---|---|---|---|
| DSCF3168 | 1.12 / 2.46 · 1.14 / 1.42 (3% of blocks) | 1.06 / 2.57 · 1.22 / 1.66 (7%) | 1.30 / 2.38 · 1.27 / 2.16 (90%) |
| DSCF3669 | 1.30 / 1.87 · 1.43 / 1.97 (6%) | 1.34 / 2.32 · 1.49 / 2.14 (15%) | 1.86 / 4.05 · 1.58 / 3.07 (79%) |
| DSCF3523 | 0.43 / 0.61 · 0.20 / 0.51 (23%) | 0.98 / 2.96 · 0.94 / 2.02 (10%) | 1.42 / 4.66 · 0.99 / 2.62 (66%) |

**Fitted tables against Lightroom's profiles,** on DSCF3168, scored as above (ΔL* is the table's brightness minus
Lightroom's):

| Look | Table fitted on | Normalized base | Table | ΔL* | Table, brightness matched |
|---|---|---|---|---|---|
| Classic Chrome | X-T1, 460 photos (Results above) | 3.79 / 6.45 | 2.59 / 4.37 | +2.8 | 1.34 / 2.52 (−0.20 EV) |
| Velvia | X-T3, 108 photos | 3.87 / 5.85 | 2.36 / 3.94 | +2.3 | 1.61 / 3.18 (−0.16 EV) |
| Provia | as above, 182 photos | 1.85 / 3.76 | 2.08 / 3.48 | +2.0 | 1.34 / 2.50 (−0.14 EV) |
| Astia | X-T1 and X-T4, one session each (30) | 2.26 / 3.94 | 3.26 / 8.22 | +2.1 | 3.14 / 6.70 |
| Pro Neg. Hi | X-T1, one session (57) | 2.65 / 5.22 | 3.99 / 7.78 | +4.0 | 2.52 / 4.94 |
| Pro Neg. Std | X-E5, 8 photos | 2.64 / 5.25 | 3.93 / 6.18 | +4.6 | 1.62 / 2.88 |

What this shows:

- **Lightroom is closer to the camera on all three photos, so decision 8 isn't met.** On the mean it's close on two
  (Provia 1.28 against 1.26; Velvia by day 1.74 against 1.56), and Lightroom is clearly ahead at ISO 3200 (1.13
  against 0.79). On p95 Lightroom is ahead on all three (2.11–2.87 against 2.41–4.26). Three photos from one body is a
  small sample, but every comparison points the same way.
- **By eye, at full size,** the two daylight photos look alike in all three: the table's rendering is a touch brighter,
  and skin a touch pinker, which takes the side-by-side to see. The concert photo (DSCF3523) shows one real color
  miss. The camera renders the neon sign's letters orange, Lightroom a pinker orange, and the table pink-red. The table
  had never seen stage lighting: refitted with the same concert's other frames (no longer a fair score, so it isn't in
  the table above), it renders the letters orange, close to the camera, and scores 1.00 / 3.95. A ProPhoto cube didn't
  help (1.52 / 4.98). So that miss is a matter of what the training covers; RAW-130's renders should include stage and
  neon light. Apple's noise reduction also leaves more color blotches at ISO 3200 than the camera or Lightroom.
- **Otherwise the gap is in detailed areas.** In flat areas the table matches Lightroom on two of the
  photos on the mean and is 0.2 behind on the third. The difference is in blocks with edges and texture: the error maps light up
  on outlines, brick joints and the frame's corners. Two things in the prototype made the table look worse there than
  it is, and RAW-128 should do both differently:
  - **The table was applied to block averages.** The fit and every other score in this write-up apply the table to
    each block's average color. PixelLoupe applies it to every pixel, as the camera and Lightroom apply their tone
    curves, and with a contrasty look a curve of an average isn't the average of a curve wherever a block has detail.
    Applied per pixel, the same tables score 0.1–0.2 lower in mean and 0.1–1.0 lower in p95 on these photos, so the
    results above are slightly pessimistic too. The fit should match: give each block the average of its pixels'
    interpolation weights instead of the weights at its average color. That's still linear least squares, but it
    needs per-pixel data in the cache. Down-weighting detailed blocks instead made things worse (it did in the method
    choices too).
  - **Lightroom frames the photo like the camera; Apple doesn't.** Lightroom applies Fujifilm's own lens corrections,
    so its export lines up with the camera's JPEG. Apple's lens correction differs by more than the global
    registration (a scale, a radial term and a shift) captures. Aligning in 64 px tiles as well brings DSCF3669 from
    2.09 / 5.09 to 1.74 / 3.79 (per pixel), and moves Lightroom by less than 0.2.

  What's left in detailed areas probably comes from the base: Apple's demosaicing, noise reduction and handling of
  color fringes differ from the camera's and Adobe's, and a color table can't change those. Even a table fitted on
  each photo itself, the best one table can do on Apple's base (scored on block averages), leaves p95 at 2.1, 5.0 and
  3.7.
- **Where the tables have enough photos behind them, they agree with Lightroom's profiles.** Classic Chrome, Velvia
  and Provia come within 1.3–1.6 mean of Lightroom once brightness is matched. In all three, Lightroom renders
  0.14–0.20 EV darker than the table. Since Lightroom's Provia is 0.09 EV darker than the camera, at least half of that
  difference is Lightroom's. The rest is the per-body brightness of finding 2: the Provia table renders this X-T3 photo
  0.05 EV too bright. A Velvia table that also had this day's camera JPEGs in its training lands closer to Lightroom
  (1.93 / 3.27), which suggests Lightroom's Velvia is close to the camera's too.
- **A session or two doesn't make a table.** Astia and Pro Neg. Hi have pairs from one or two sessions, and Pro Neg.
  Std has eight photos. As rendered, their tables are further from Lightroom than the plain normalized base is, and
  Astia's, held out on the X-T4, scored 3.97 against the normalized base's 2.80. A look needs pairs from varied scenes,
  which is what RAW-130's X RAW STUDIO renders are for.
- **Lightroom's list for the X-T3 is the camera's own menu:** Provia, Velvia, Astia, Classic Chrome, Pro Neg. Hi and
  Std, Eterna, and Acros and Monochrome, each plain or with a yellow, red or green filter. Sepia is the only one
  missing. The names as a catalog records them (`crs:CameraProfile`), for decision 10's import mapping: "Camera
  PROVIA/STANDARD v2", "Camera Velvia/VIVID v2", "Camera ASTIA/SOFT v2", "Camera CLASSIC CHROME v2", "Camera Pro Neg.
  Hi v2", "Camera Pro Neg. Std v2", "Camera ETERNA/Cinema v2", "Camera ACROS v2", "Camera ACROS+Ye FILTER v2" (and +R,
  +G), "Camera MONOCHROME v2", "Camera MONOCHROME+Ye FILTER v2" (and +R, +G).

## Findings

1. **The base doesn't vary by photo, but its brightness varies by body and ISO.** On Fujifilm, the RAW engine's
   local tone mapping, shadow bias and boost are the same on every photo, so the design's worry about per-photo
   settings doesn't arise here. What does vary:
   - **By body:** `CIRAWFilter.baselineExposure` is −0.70 for the X-T1 and X100T, +0.02 for the X-E3, X-T2 and X-T4,
     +0.12 for the X-T3 and +0.22 for the X-T10 and X-E5. The camera's JPEGs don't follow it: with it cancelled
     (`exposure = −baselineExposure`), Default's mean brightness is within 1.6 L* of the camera's Classic Chrome JPEGs
     on every body.
   - **By ISO (X-T1):** above ISO 2000 the camera underexposes and pushes in processing, recording it in the RAF
     header's `RawExposureBias` (tag `0x9650`: −0.72 EV up to ISO 1600, −0.96 at 2500, −1.71 at 4000, −1.74 at 5000,
     −2.31 at 6400). Apple's engine ignores it, so Default renders those photos 0.2–1.6 EV too dark (ΔE00 22 at
     ISO 6400). The exposure offsets fitted per ISO matched the recorded push within 0.25 EV (ISO 6400: +1.51
     fitted, +1.59 recorded).
   - **By D-Range and extended ISO:** `RawExposureBias` also records D-Range 200% (−1.72 EV on the X-T3 and X-E5) and
     the extended ISO 80 (+0.28 EV, X-T3); the X-E3 and X-T2 record −0.72 at every ISO. The engine's own baseline
     exposure already follows D-Range: on the X-T10 it's +0.22 at 100%, +1.22 at 200% (`RawExposureBias` −1.72) and
     +2.04 at 400% (−2.54), so the formula below gives −0.22 EV at all three. D-Range above 100% was still left out of
     the fits, as decided (its tone is adaptive).

   So a camera-matching profile sets the RAW engine's exposure to
   `user Exposure − baselineExposure − (RawExposureBias + 0.72)` for Fujifilm. The Exposure slider still adds, White
   Balance is untouched, and the profile's Amount doesn't change it. Other makes need their own push tag, if any.
2. **The brightness is part of the look.** With the base normalized, the best exposure per photo varies by 0.06 EV
   (sd) within a body, and fitting it per photo would gain 0.06 ΔE00 at most. A body can still sit a little off: the
   X-E3 wants −0.11 EV (1.78 → 1.17 with it), the X-T10 −0.08. A per-body offset in the profile is a refinement for
   later, not needed to clear the bar.
3. **17³ in sRGB is enough, with the tone baked in.** Going from 9³ to 49³ gains 0.09 ΔE00, so the table's
   resolution isn't what limits it, and a separate tone curve couldn't add accuracy. P3 and ProPhoto cubes did no
   better, for Classic Chrome or for the saturated Velvia. As an Adobe profile, a 17³ table is 34 KB (33³: 246 KB).
4. **Smoothing:** λ = 1e-6 (relative to the data term, scaled with the table's spacing). The tables at 1e-4 to 1e-6
   have no brightness inversions anywhere in the cube and keep the neutral axis neutral (C* ≤ 1); at 1e-7, 0.08% of
   steps invert (by up to 2.2 L*). The fitted tone curve deepens shadows (L* 12 → 9.5) and lifts mid-tones and
   highlights (53 → 57, 77 → 80.5).
5. **The pipeline order is right as it is.** Exposure and White Balance happen in the RAW engine, before the profile,
   as in the camera. Rendered at Exposure ±1 EV and at As Shot −1500 K and +2500 K, the table showed no banding,
   clipping or hue flips: it keeps its character on colors and brightnesses the training photos didn't reach. The
   highlight and shadow filter runs before the profile, as it already does for Adobe profiles; its output is then
   shaped by the profile's tone curve, as Fujifilm's own Highlight and Shadow tone are by the film simulation. No change
   needed.
6. **Embedded previews are as good as FINE JPEGs for color.** Fitted on the RAF's embedded preview instead, the table
   scored the same against the camera JPEG (1.15 / 3.18 against 1.18 / 3.15). Re-encoding the camera JPEG at quality
   75, as hard as other makes' full-size previews, moves the block averages by ΔE00 0.12 mean / 0.39 p95. Grain still
   needs full-size camera JPEGs (decision 5).
7. **One table per look holds across sensor generations (decision 7).** The Classic Chrome table from the X-T1 did
   as well on the X-T10 and X100T as on the X-T1, and nearly as well on the X-E3. For Velvia, a table fitted on one
   generation did about as well on the others as on its own (the X-T3's table: 1.69 on the X-E3, 2.96 on the X-T4;
   the X-T1's: 2.36 on the X-T3), and a table pooled from all bodies did best. What remains per body is brightness,
   at most about 0.2 EV (X-E5 +0.16 to +0.23, X-E3 −0.11), and the X-E5 has only one session of 21 photos.
8. **Pairs need registering.** On some lenses the camera's JPEG and Apple's lens correction frame the photo up to 3%
   differently (some X-T3 photos: correlation 0.16–0.38 unregistered, 0.47–0.82 registered), which turned edges into
   ΔE 12+ and hid the color fit. A scale, a radial term and a shift fix it; rendering with the engine's lens
   correction off instead registered worse on 8 of 10 test photos.
9. **The shipping path works.** A fitted table written as an Adobe RGB-table profile (`crs:RGBTable`, sRGB) loads in
   PixelLoupe's `AdobeProfile` and renders through `CIColorCubeWithColorSpace` within 0.4/255 of the prototype's own
   lookup (p99 under 1/255). So decision 9 holds; the base normalization (finding 1) is the one rendering change.
10. **The camera renders warm light differently.** Under tungsten-like light (As Shot under 3800 K) the error roughly
    doubles. In the worst photos (a lamp-lit room) the camera keeps the yellow walls lighter and cleaner than a table
    trained mostly on daylight does, which makes them deeper and more orange; Default is closer there. For Velvia that's the main miss (X-T1 held out: 3.9 under 3800 K
    against 1.8 above), and splitting the training by light improves both halves (warm 3.85 → 3.10, daylight
    1.62 → 1.48). Classic Chrome copes with one table (2.2 under warm light, 1.2 in daylight). The fix is the DNG
    profiles' own: two tables, for warm light and daylight, blended by the photo's white balance.
11. **Where it misses otherwise:** mixed light (an interior lit by daylight and blue light: 2.4), the high-ISO photos
    (2.1, where the camera's noise reduction and tone differ) and single sessions (an X-T2 indoor burst 4 L* too dark).
    These are adaptive processing, or the scene, that no global table can follow.

## Left open

- **Decision 8:** on three X-T3 photos Lightroom is closer to the camera (above), so Ted has put the build on hold
  rather than build on the fallback bar ([Recommendation](#recommendation)). Whatever the base when it resumes, more
  exports of photos whose camera JPEG used the same look, from days the fit didn't see, would firm it up: the held-out
  Classic Chrome RAF files (lists in the notes folder) with "Camera CLASSIC CHROME v2" would test a second body and
  look. Scoring them is the `trio` command.
- **Warm light:** whether looks like Velvia need a second table (finding 10). It needs more warm-light pairs than this
  library has (38 X-T1 Velvia photos under 3800 K): X RAW STUDIO renders of indoor RAF files (RAW-130) would do.
- **Per-body brightness:** whether profiles carry a small exposure offset per body (finding 2), up to about 0.2 EV.
- **Default's high-ISO brightness** (finding 1) is a Default problem for every X-T1 photo above ISO 2000, not only
  profiles: RAW-137.

## Recommendation

- **On hold (Ted, 2026-10-20).** Lightroom beats decision 8's bar on the photos so far
  ([Against Lightroom](#against-lightrooms-camera-matching-profiles)). RAW-127 to RAW-135 are labelled `on-hold` until
  Ted has looked into a platform-independent RAW parser to replace Apple's RAW engine. The rest of this section is the
  plan for when they resume. The fitting method, the pair checks and the maker-note reader don't depend on the engine.
  The tables and the brightness corrections (findings 1 and 2) were measured on Apple's engine and would be redone on
  a new one.
- **RAW-128, the fitting tool:** the method above: Default with sharpening off; the base normalized (finding 1); pairs
  checked, de-duplicated and registered; 8 × 8 block averages of 1536 px images; one 17³ sRGB-encoded table,
  trilinear, least squares with a second-derivative penalty (λ 1e-6), coarse to fine; blocks weighted equally;
  sessions held out and scored per body and by the light; all ISOs once normalized. Pool every body's pairs for a look.
  Two changes from the prototype, both from the Lightroom comparison: fit and score the table as applied to every
  pixel (each block gets the average of its pixels' interpolation weights), and align each pair in tiles as well as
  globally. Score against Lightroom's exports where there are any.
- **RAW-129:** a camera-matching profile carries the base normalization: `DevelopSource` sets the RAW engine's
  exposure offset (finding 1) when the photo's profile is a bundled camera-matching one. Profiles ship as 17³ RGB-table
  profiles (34 KB each). Each look is scored against the bar per body and by the light; a look that misses under warm
  light gets a second table blended by white balance (finding 10), which is a small addition to the profile format
  and its rendering.
- **RAW-127, the maker-note reader:** also read Fujifilm's `RawExposureBias` from the RAF header (and look for other
  makes' equivalents), since the profile and the training both need it.
- **RAW-130:** add indoor, warm-light RAF files to the X RAW STUDIO renders, for the warm-light tables.
