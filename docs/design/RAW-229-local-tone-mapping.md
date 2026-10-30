# RAW-229 spike: Shadows, Highlights and Clarity like Lightroom's

**Question:** after RAW-229 tuned the Lightroom → PixelLoupe slider mapping (Busy City from 8.6 to 7.0 ΔE00 against
Lightroom's export), would rendering Shadows, Highlights and Clarity the way Lightroom does, with edge-aware local
tone mapping, close more of the gap? And what would it cost?

**Answer:** edge-awareness isn't what's missing, on either of the two photos measured (a studio portrait and a backlit
subject against a bright sky). What helps is the *shape* of Shadows: a lift measured in stops that fades out with
brightness, instead of Core Image's `CIHighlightShadowAdjust`. Lightroom's strength also varies from photo to photo;
see "Second photo" below.

- **Shadows:** a per-pixel version brings the four sweeps from 2.48 to **1.95** mean ΔE00, with the biggest gains on
  lifts: +50 drops from 1.70 to 0.88, +100 from 3.75 to 2.84. Adding an edge-aware base doesn't improve on that (1.96).
  It fits in PixelLoupe's existing color table, so it costs nothing at render time.
- **Highlights:** the same model is better for pulling highlights down (−100: 1.77 → 1.46, −50: 0.91 → 0.78) but worse
  for raising them, where the current renderer is already within 0.7. Mixed, so it isn't worth a change on its own.
- **Clarity:** no model I tried beat the current unsharp mask with RAW-229's table (1.68). Log-domain local contrast
  scored 1.98, and with a midtone contrast term 1.91. Lightroom's Clarity really does make the wide dark halo seen in
  Busy City, and the current renderer's halo is the closest match so far.

## Method

- **References:** Ted's Lightroom exports of `5D3_9264.CR2` (16-bit Display P3, 2048 px): the unedited photo, and
  one-slider sweeps of Shadows, Highlights and Clarity at −100, −50, +50 and +100 on it.
- **Prototypes** run on the CPU at 384 × 256, starting from *Lightroom's* unedited export. That isolates each operator
  from PixelLoupe's baseline, which is 0.59 ΔE00 off on this photo.
- **One set of constants per operator** has to serve all four of its sweeps (coordinate descent on the mean ΔE00). The
  slider value goes in linearly, so a match means the operator itself behaves like Lightroom's, not that a table hides
  the difference.
- **The current renderer's numbers** are its best value for each sweep separately (RAW-229's tables). That's generous
  to it, so the Shadows win is if anything understated.

The prototypes:

- **Shadows / Highlights:** `rgb × 2^(amount · k · w(v))`. Here `v` is the perceptual brightness of the pixel or of its
  guided-filtered neighborhood in log luminance; `w = (1 − v)^p` for Shadows and `v^p` for Highlights. A gain in stops
  keeps color ratios and texture, and fades smoothly toward white (Shadows) or black (Highlights). Fitted Shadows:
  `k` = 2.8 lifting and 2.1 darkening, `p` = 2.3.
- **Clarity:** `rgb × 2^(amount · k · (log Y − base))`, where the base is a Gaussian or guided blur at 0.5–15 % of the
  long edge, optionally weighted toward midtones and with a midtone contrast term.

| Mean ΔE00 over 4 sweeps | Current (per-sweep best) | Prototype, per-pixel | Prototype, edge-aware |
| --- | --- | --- | --- |
| Shadows | 2.48 | **1.95** | 1.96 |
| Highlights | **0.99** | — | 1.45 |
| Clarity | **1.68** | — | 1.91 |

By eye, the Shadows prototype keeps the background dark and the skin bright, as Lightroom's +100 does. The current
renderer lifts everything into a brown haze.

## Options

1. **Leave the renderers alone.** RAW-229's tables stay the only change. Busy City stays at about 7 ΔE00.
2. **Replace Shadows with the per-pixel gain for all edits** (recommended). It's a change to `ColorLUT.lightTone` (or a
   new stage of the color table), with no new pass, so speed is unchanged. Two catches:
   - **Existing edits would change.** Anyone who set Shadows in PixelLoupe gets a different render. PixelLoupe has no
     process version today. Adding one to `PhotoAdjustments.Light` (old photos keep `CIHighlightShadowAdjust`, new and
     imported ones get the new curve) is what Lightroom does. It needs no new Core Data model version, because adjustments
     are stored as JSON in `Photo.adjustmentsData`; a missing field decodes as the old process.
   - **`LightroomScales.shadowsTable` gets re-fitted** to the new operator (close to linear, given how the prototype fit).
3. **A Lightroom-only path for imported settings.** The same sliders would render two ways depending on where the
   values came from. That's confusing to use and to maintain, so I don't recommend it.

Highlights and Clarity: no change recommended from this data.

## Second photo: a backlit subject against a bright sky

Ted exported a Shadows sweep of `5D3_5129.CR2` (2013-06-11): a backlit subject in front of a bright, hazy skyline,
which is where a per-pixel lift would haze the sky if Lightroom's were local. Same method; "bright" is the mean ΔE00
over pixels with L\* > 75 in Lightroom's unedited export (sky, glass), "dark" over L\* < 30.

| Shadows | Untouched | Current, best value (from the RAW) | Prototype, Busy City constants | Prototype, fitted here | Edge-aware, fitted here | Prototype, one set for both photos |
| --- | --- | --- | --- | --- | --- | --- |
| −100 | 6.35 | 6.95 at −0.10 | 4.40 | 1.82 | 1.65 | 2.21 |
| −50 | 3.64 | 4.34 at −0.10 | 2.60 | 1.16 | 1.08 | 1.39 |
| +50 | 4.22 | 3.09 at 0.66 | 2.64 | 1.38 | 1.30 | 1.97 |
| +100 | 8.78 | 4.86 at 0.97 | 5.24 | 2.61 | 2.47 | 3.86 |
| Mean | 5.75 | 4.81 | 3.72 | **1.74** | 1.62 | 2.36 |

The current renderer's column starts from PixelLoupe's own render of the RAW, which is 1.69 off Lightroom's before any
change, so it isn't directly comparable; its untouched mean on that footing is 6.35.

- **The sky doesn't haze.** The per-pixel prototype's bright areas stay within 0.5–0.9 ΔE00 on every step, and
  edge-awareness improves the mean by only 0.12. That settles the open question: per-pixel is enough.
- **The current renderer can't darken this photo.** Its best value for −50 and −100 is about −0.1, no better than
  leaving the slider alone, and RAW-229's `−100 → −1` makes it worse (7.73), because it also darkens the bright areas.
- **Lightroom's strength depends on the photo.** Fitted alone, this photo wants about twice Busy City's strength
  (lift 4.25 against 2.81, darken 4.5 against 2.13). The current renderer shows the same thing: +50 matches 0.66 here
  and 0.395 on Busy City, so RAW-229's table is right for Busy City and too weak here. Lightroom's Shadows is evidently
  image-adaptive.
- **One set of constants for both photos** (lift 3.0, darken 3.75, power 1.75) scores 2.36 here and 2.60 on Busy City,
  against 1.74 and 1.95 fitted to each. On Busy City that's 0.12 worse than the current renderer at its per-sweep best;
  here it's far better, especially when darkening.

**Updated recommendation:** option 2 still stands, per-pixel, with the shared constants. An adaptive strength (scaled by
something like the photo's median brightness or the share of it in shadow) would close most of the remaining gap, but
two photos can't fit a rule like that. It needs three or four more Shadows sweeps of different kinds of photos (a low-key
interior, a bright beach or snow scene, a flat overcast landscape) and is better as a follow-up after option 2.

## Built (RAW-230): measured in the real pipeline

RAW-230 builds option 2: the gain runs in the color table, after the profile and calibration and before the tone curve,
for photos on the new Shadows process. Rendered from the RAWs at the shared constants, against Lightroom's sweeps
(mean ΔE00, including each photo's baseline difference: 0.59 for Busy City, 1.69 for `5D3_5129`):

| Shadows | Busy City, original process with RAW-229's table | Busy City, per-pixel | `5D3_5129`, original process | `5D3_5129`, per-pixel |
| --- | --- | --- | --- | --- |
| −100 | 2.72 | 3.68 | 7.73 | 2.83 |
| −50 | 1.88 | 2.74 | 4.83 | 2.23 |
| +50 | 1.70 | 1.58 | 3.59 | 2.66 |
| +100 | 3.75 | 3.97 | 5.34 | 4.39 |
| Mean | 2.52 | 2.99 | 5.37 | 3.03 |

Across both photos that's 3.95 → 3.01. Busy City gets worse when darkening, because one strength can't suit both
photos; that's the adaptive-strength follow-up. Refitting the three constants in the pipeline instead of on Lightroom's
export moved the mean by less than 0.01, so they stay as fitted: lift 3.0, deepen 3.75, falloff 1.75.

## Caveats and what to do before building

- **Two photos.** Both are portraits from one camera. More sweeps (above) would show how far the shared constants
  carry, and whether an adaptive strength is worth it.
- **Not measured on Busy City as a whole.** That needs the operator in the real pipeline, before the profile and color
  table. The harness is quick to repeat: the operators are about 150 lines (kept out of the repo, ask for them).
- **If a local base turns out to be needed** (the landscape check), Core Image's `CIGuidedFilter` does nothing on this
  system (see `GuidedMatte`). The base would come from a small copy on the CPU, as Rim Light's matte does, or from a
  `.ci.metal` box-filter kernel like the panorama merge's. Either way it's an extra pass, so check slider responsiveness
  on a large catalog.

## Adaptive strength (RAW-231)

Ted exported Shadows sweeps of eight more photos (A–H: Sony ARW, Fuji RAF, Nikon NEF; portraits, interiors, landscapes,
one monochrome), so ten in all. C's +50 was exported at −3 and is left out. Each operator was scored on Lightroom's own
unedited export, as in the spike, at 320 px on the long edge.

**Lightroom's Shadows strength varies about tenfold between photos**, from about 0.5 to 5–7 stops at full Shadows, and
one number predicts it: the photo's bright end, the 95th percentile of its encoded luminance (`p95`). That correlates at
+0.9 with the fitted strength both ways. What counts as a shadow is relative to the same bright end, too. The model:

- `v' = min(v / p95, 1)`, so the photo's brightest tones are left alone;
- `stops = amount × k × (1 − v')^1.75`, with `k = min(exp(a + b × p95), cap)`;
- lifting `a = −1.682, b = 3.271`, cap 4; deepening `a = −1.888, b = 3.585`, cap 5. The cap stops a clipped photo
  (`p95` = 1) from overshooting.

Mean ΔE00 over the ten photos on Lightroom's export, each photo's rule fitted on the other nine:

| Model | Lift | Deepen |
| --- | --- | --- |
| RAW-230: fixed strength 3.0 / 3.75 | 5.03 | 3.98 |
| Best fixed strength | 4.59 | 2.78 |
| Relative to `p95`, fixed strength | 3.18 | 2.16 |
| Strength from `p95` | 2.49 | 1.58 |
| **Both, capped** | **2.11** | **1.36** |

Against RAW-230's fixed strength, the worst regressions are Busy City's lift (+0.87, the photo RAW-230 was tuned on) and
F's deepening (+0.15). Every other photo improves, most of them a lot (B's lift 10.4 → 0.8, D's 8.1 → 1.0).

**In PixelLoupe** the reference is measured once per photo (`DevelopSource.shadowsReference(exposure:)`): the decoded
photo at its defaults, at 256 px, then moved by the photo's exposure. It goes into the color table's key, rounded to
0.01, and masks use the photo's. From the RAWs against Lightroom's sweeps:

| Photo | PixelLoupe baseline | Original process | Adaptive per-pixel |
| --- | --- | --- | --- |
| Busy City | 0.44 | 2.42 | 2.69 |
| `5D3_5129` | 1.80 | 5.42 | 2.53 |
| F | 2.32 | 4.55 | 3.33 |
| H | 1.53 | 4.51 | 2.31 |

A–E and G aren't comparable this way: they use Lightroom's camera-matching profiles (Camera VV2, Classic Chrome,
Monochrome), which PixelLoupe doesn't have yet, so they start 5–13 ΔE00 off. PixelLoupe's decode of them is also darker
at the bright end than Lightroom's, so their measured reference is lower (E 0.49 against 0.67) and the lift too gentle.
That should resolve with the profiles.

Not known: whether Lightroom's reference moves with Exposure. PixelLoupe's does, scaled in linear light.
