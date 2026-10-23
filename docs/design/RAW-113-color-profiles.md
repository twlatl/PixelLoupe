# RAW-113 spike: camera-matching color profiles

**Question:** can PixelLoupe offer profiles that match what the camera does in camera (Fujifilm's film simulations,
Nikon's Picture Controls, Canon's Picture Styles and the like), as Lightroom's Camera Matching profiles do, by reverse
engineering them from sample images?

**Answer:** very likely, as a fitting problem, but not yet measured. Render the same RAW file two ways, through
PixelLoupe's Default rendering and as the camera's own JPEG with the look chosen, and fit a smooth color transform
(a 3D table with the tone curve baked in) from one to the other. The risks are coverage (photos don't sample every
color, so a color chart is needed too), the cameras' adaptive processing (which no global table can reproduce, so
samples are shot with it off), and the brightness baseline (Apple's rendering and the camera's differ). A prototype
fitting one look decides whether to go ahead; see [Decisions](#decisions) and [Tickets](#tickets).

## What PixelLoupe has today

- **Two kinds of profile**, both in the Profile pop-up at the top of Basic, with an Amount slider (0–200):
  - **PixelLoupe's own looks:** Default, Neutral, Vivid, Landscape, Portrait and Monochrome, hand-tuned curves and
    saturation folded into the shared table (`ColorLUT.Transform.look`).
  - **Imported Adobe profiles:** `.xmp` files with `crs:PresetType="Look"`, copied into
    `~/Library/Application Support/Pixegen/PixelLoupe/Profiles` when the user imports Lightroom's presets
    (`AdobeProfileLibrary.importProfile`). `AdobeProfile` decodes their look table and RGB table into color cubes,
    and their extra settings (clarity, curves, vignette) apply as hidden settings (`AdobeProfileLook`). Profiles
    restricted to a camera (`crs:CameraModelRestriction`) are listed under "Camera Matching", for that exact model.
- **Everything sits on Apple's rendering.** RAW files go through `CIRAWFilter`, and the profile cubes are applied to
  its display-referred output, after highlights and shadows and before the shared table (`DevelopSource`). Adobe's
  tables were designed for Adobe's own base rendering, so imported Adobe profiles are already approximate.
- **Lightroom catalogs:** `LightroomDevelopMapper.profileMapping` maps Adobe Color, Adobe/Camera Vivid, Landscape,
  Portrait, Monochrome and Neutral to PixelLoupe's own looks ("approximated"). Every other name, such as
  "Camera CLASSIC CHROME v2", imports as Default and is reported by name.

## What Lightroom has (Lightroom Classic on this Mac)

- **Camera Matching profiles are mostly `.dcp` files** (DNG Camera Profiles, a format in Adobe's public DNG
  specification): `CameraProfiles/Camera/<model>/` in the app bundle and in
  `/Library/Application Support/Adobe/CameraRaw`, 395 camera folders across Canon, Nikon, Sony, Panasonic, Olympus,
  OM System, Pentax, Leica, Ricoh and Sigma. The Nikon Z 6III has 18 (Standard, Neutral, Vivid, Flat, Portrait,
  Landscape, Rich Tone Portrait, Flexible Color, the Monochromes and the HDR variants). PixelLoupe can't read them.
- **Fujifilm's core film simulations aren't files at all.** PROVIA, Velvia, ASTIA, Classic Chrome, PRO Neg., ETERNA
  and ACROS (the list in the ticket's first screenshot) appear nowhere on disk by name; they seem to be built into
  Camera Raw. Only CLASSIC Neg., NOSTALGIC Neg., Bleach Bypass and Sepia ship, as `.xmp` files.
- **Those `.xmp` camera looks are a table on top of a `.dcp`:** the Fujifilm ones say
  `crs:CameraProfile="Camera PROVIA/Standard"`, and Nikon's Creative Picture Controls (Dream, Morning, Pop, Denim…,
  the ticket's second screenshot) say `crs:CameraProfile="Camera Standard"`. PixelLoupe drops that key
  (`AdobeProfileLibrary.hiddenSettings`), so when imported they render on PixelLoupe's Default, not on the base they
  were made for.

## Decisions

Settled with Ted on 2026-10-20.

1. **The target is the camera's own JPEG**, as rendered by the camera or by the maker's own desktop software from
   the same RAW file, not Lightroom's Camera Matching rendering. Adobe's profiles are themselves an approximation of
   the camera, and for Fujifilm they can't be read anyway. Lightroom switchers still benefit through decision 10.
2. **Supporting the DCP format is its own Task**, outside the fitting work and not blocked by it: read and render
   `.dcp` files, whichever the user has (Adobe's from their own Lightroom install, or custom ones from ColorChecker
   Camera Calibration, Lumariver or dcamprof). Nothing of Adobe's is reverse engineered or redistributed; Adobe's
   files are copied into PixelLoupe's profile library at import, as the `.xmp` profiles are now. It also gives the
   imported Fujifilm and Nikon `.xmp` looks the base they name.
3. **A fitted profile is global color and tone, plus grain where the look itself has it.** One 3D table (tone baked
   in) through the existing `PhotoAdjustments.Profile` and color-cube path, with Amount. Clarity, sharpening, noise
   reduction and the cameras' adaptive or local processing are out: Fujifilm's D-Range, Color Chrome Effect and
   Highlight/Shadow tone, Nikon's Active D-Lighting, Canon's Auto Lighting Optimizer, Sony's DRO. Samples are shot
   with those off. Monochrome looks (ACROS, Monochrome and the filter variants) are profiles like any other.
4. **A prototype comes first.** RAW-113 closes after a prototype has fitted one look and measured it; the build
   tickets are proposed now but blocked by it, since its numbers decide whether to go ahead and how.
5. **Grain:** a look's own grain (Fujifilm describes ACROS as adding a grain-like texture that grows with ISO) is
   carried by the profile as a hidden setting, scaled by Amount, and used only when the photo has no Grain of its
   own, the rule hidden curves and vignettes already follow. Fujifilm's separate Grain Effect setting (Weak or
   Strong, Small or Large) becomes ordinary develop presets that set the visible Grain sliders. Grain is fitted
   from its statistics (strength by brightness, size from its spectrum) at full size, separately from color, which
   is fitted on downscaled images where grain averages out.
6. **Names evoke the original without using the makers' marks** (decision 11 gives the scheme).
7. **One profile per look per brand** by default. PixelLoupe's base, Apple's rendering, already corrects each
   camera's sensor color, so one fit may hold across a brand's bodies. Where two bodies are available, the
   prototype fits on one and tests on the other; per-model or per-sensor-generation versions are added only if that
   error fails the bar in decision 8.
8. **Go/no-go bar:** at least as close to the camera's JPEG as Lightroom's own Camera Matching profile is, measured
   the same way: ΔE2000 mean and p95 on photos left out of the fit, against Ted's Lightroom exports of the same RAW
   files. Without a Lightroom rendering to compare, mean ≤ 3 and p95 ≤ 6. A side-by-side check of skies, skin and
   foliage too.
9. **Fitted profiles ship inside the app** as profile files in the format `AdobeProfile` already renders (an RGB
   table), so no new rendering code; about 100 KB per look. They're listed in the Profile pop-up's Camera Matching
   group, filtered by the photo's **make** (the group filters by exact model today, so it gains a make filter).
10. **Lightroom catalog import** maps camera-matching names ("Camera CLASSIC CHROME v2", "Camera Velvia/Vivid",
    "Camera Flat"…) to the matching PixelLoupe profile, reported as "approximated", instead of Default.
11. **Naming scheme:**
    - Ordinary words the makers also use keep their names: Standard, Neutral, Vivid, Flat, Portrait, Landscape,
      Faithful, Monochrome, Sepia, Bleach Bypass, the filter names, and Nikon's creative ones (Dream, Morning, Pop,
      Denim, Toy…).
    - Coined look names get evocative ones of our own. Fujifilm:

      | Fujifilm | PixelLoupe |
      |---|---|
      | PROVIA/Standard | Standard Slide |
      | Velvia/Vivid | Vivid Slide |
      | ASTIA/Soft | Soft Slide |
      | CLASSIC CHROME | Muted Chrome |
      | PRO Neg. Hi / Std | Portrait Negative Hi / Portrait Negative |
      | CLASSIC Neg. | Snapshot Negative |
      | NOSTALGIC Neg. | Amber Negative |
      | REALA ACE | Natural Negative (decision 19) |
      | ETERNA/Cinema | Cinema |
      | ETERNA Bleach Bypass | Bleach Bypass |
      | ACROS (+Ye, R, G) | Fine Monochrome (+ Yellow, Red, Green Filter) |
      | Monochrome (+Ye, R, G) | Monochrome (+ Yellow, Red, Green Filter) |
      | Sepia | Sepia |

      Others (Panasonic's L.ClassicNeo, Olympus's i-Enhance…) get the same treatment when their brand comes up.
    - The maker's company name appears only to say which cameras a profile is for: a "Fujifilm" group under Camera
      Matching, shown for Fujifilm photos. No maker's look name appears in the app or the README, except in the
      Lightroom mapping (internal) and the import report, which quotes the catalog's own value
      ("Camera CLASSIC CHROME v2 → Muted Chrome, approximated").
12. **This write-up** lives here, uncommitted like the RAW-85 spike write-ups, with a summary comment on RAW-113.
13. **Training data is Ted's own library**, with the photos never leaving the Mac or entering the repo; only the fitted
    tables ship (a 33³ color table holds no image content). Targets, best first: the camera's JPEG beside the RAW,
    once checked as a real pair (size, camera firmware in Software, a pixel comparison with the embedded preview);
    otherwise the RAW's embedded preview, for color only; full-size camera JPEGs for grain. Looks with too few
    samples are filled with each maker's free software, which Ted installs and runs: FUJIFILM X RAW STUDIO with the
    X-E5 connected (CLASSIC Neg., NOSTALGIC Neg., ETERNA, Bleach Bypass, REALA ACE, Sepia, the filter variants, and
    the Grain Effect settings), NX Studio, Digital Photo Professional and Imaging Edge. A color chart is optional.
14. **The prototype fits Classic Chrome**: on X-T1 pairs, tested on held-out X-T1 photos and then on the X-E3 and
    X-E5 (other sensor generations, decision 7), against Ted's Lightroom exports of the held-out RAW files with
    "Camera CLASSIC CHROME v2" (decision 8). Velvia, which has pairs from four sensor generations, is the fallback.
15. **Order:** Fujifilm first, then Nikon, Sony and Canon, a Task each, all blocked by the prototype. Panasonic and
    OM System/Olympus get no ticket until there are samples (none on this Mac). **Scene-adaptive looks are out**
    (Nikon's Auto Picture Control, Canon's Auto Picture Style), like the rest of the adaptive processing.
16. **Camera Settings at import:** Settings ▸ Import gains "Profile for RAW files: Default / Camera Settings". The
    default is Default, so nothing changes unless the user opts in. It applies when photos are imported, and falls
    back to Default when the look has no PixelLoupe profile. Reading the look from the maker notes is its own Task,
    not blocked; the fitting tool uses it too, to sort training photos by look.
17. **The fitting tool is committed** as a command-line target sharing PixelLoupe's rendering code, so its base is
    exactly the app's Default. Photos are passed by path, never committed; its output goes into the app's bundled
    profiles, and each profile records the macOS and RAW engine version it was fitted on. Profiles are re-fitted and
    re-measured when a macOS update changes Apple's RAW rendering (PixelLoupe doesn't pin `CIRAWFilter`'s decoder
    version). A unit test checks every bundled profile loads and is listed. The prototype itself is throwaway scratch
    code, as the RAW-85 spikes were.
18. **Adobe Standard and Adobe Color in Lightroom imports:** once DCP support lands, a catalog photo set to Adobe
    Standard renders through the camera's Adobe Standard DCP when it has been imported, and one set to Adobe Color
    through it with Adobe Color's table on top: closer to how it looked in Lightroom. Photos already imported keep
    what they have; new PixelLoupe photos keep Default.
19. **REALA ACE** is named Natural Negative.

Decisions 18 and 19 were put as recommendations and taken as accepted when Ted approved creating the tickets; say
if either should change.

## Samples on this Mac

A survey on 2026-10-20 (Spotlight and ImageIO, read-only; scripts and per-camera counts in the session notes folder,
`RAW-113-survey/`):

- **About 26,300 camera RAW files:** NEF 7,957, CR2 7,223, RAF 6,598, ARW 3,382, plus DNGs (most of them Lightroom
  conversions, whose only preview is Adobe's). No CR3, ORF, RW2 or PEF, and nothing from Panasonic, OM System,
  Olympus or Pentax.
- **About 9,860 have the camera's own JPEG beside them:** Fujifilm 4,311, Nikon 2,993, Sony 2,056, Canon 472. Some
  same-name matches aren't pairs (a re-save, an unrelated photo), hence the checks in decision 13.
- **Every RAW embeds the camera's rendering in the look chosen at capture**, 0.1–0.9 out of 255 from the camera's
  JPEG (Apple's rendering is 2–36 away). Full size for Nikon, Canon CR2 bodies and the Sony α7 IV and α7CR (the
  Sony one isn't listed by ImageIO and has to be found in the file); 4416 px for Fujifilm X-T3 and later, 1920 px
  for older Fujifilm bodies; 1616 px for the Sony α6600 and α7C. The full-size ones are compressed harder (about
  quality 75–82) than the camera's FINE JPEGs.
- **Fujifilm looks with a camera JPEG:** Classic Chrome 1,591 (1,468 from the X-T1, the rest from the X-E3, X-E5,
  X-T10 and X100T), Velvia 1,677 (X-T1, X-T2, X-E3, X-T3, X-T4 and X-E5), Monochrome 436, Provia 301, ACROS 107,
  Pro Neg. Hi 59, Monochrome + G 55, ASTIA 30, Pro Neg. Std 24, REALA ACE 2, ETERNA 1; none for CLASSIC Neg.,
  NOSTALGIC Neg., Bleach Bypass or Sepia. Nikon: Vivid 1,147, Auto 1,454 (all D850), Monochrome 218, Standard 108,
  Flat 76. Sony: Vivid 999, VV2 509, Standard 434, B&W 72, Neutral 42. Canon: Monochrome 287, Standard 185 (and
  2,616 Faithful RAW files with full-size embedded previews).
- **The look is recorded in every RAW's maker notes, but ImageIO barely shows it.** The documented maker
  dictionaries have nothing; an undocumented `{PictureStyle}` dictionary gives Fujifilm codes (and nothing for ACROS
  or filtered monochrome), nothing for Nikon Z bodies, never Canon's style, and Sony's VV2 as a number. A small
  parser for four tags (Fujifilm `0x1401` FilmMode, `0x1003` Saturation and `0x1031` PictureMode; Nikon `0x0023`
  PictureControlData; Canon `0x00A0` ProcessingInfo, element 10; Sony `0xB020` CreativeStyle, numbers from ExifTool's
  tag tables) read a look from all 25,160 non-DNG RAW files, agreeing with ImageIO wherever both read one.
- **No camera maker's software is installed.**

## Left to the prototype

*Answered by RAW-125 in [the prototype write-up](RAW-113-prototype.md): go, with the base normalized for brightness
by body and ISO, one 17³ sRGB table per look, and a possible second table for warm light. That's on the fallback bar:
on the three photos Ted exported from Lightroom so far, Lightroom's Camera Matching profiles are closer to the camera,
so decision 8's own bar isn't met yet. Ted put the build on hold on 2026-10-20 (see [Tickets](#tickets)).*

Questions of method the prototype answers, not decisions to make now:

- **The base:** fit on PixelLoupe's Default as it is, or have a camera-matching profile fix the RAW engine's
  settings that vary its output by photo (local tone mapping, shadow bias, boost), as the Smart Preview writer does
  for its own decodes. Whatever the answer, choosing the profile mustn't make the photo's other sliders behave
  differently.
- **The brightness baseline:** whether the camera's exposure offset from Apple's rendering is part of the look or
  fitted out per photo.
- **The table:** its size and color space, whether a separate tone curve fits better than one baked in, and how the
  fit is kept smooth where the photos have no samples.
- **The pipeline:** how the profile stage interacts with Exposure, White Balance and the highlight and shadow
  filter, which runs before it.
- **The targets:** how much the full-size embedded previews' heavier compression costs against FINE JPEGs.

## Tickets

Created on 2026-10-20. RAW-125 reported the same day ([the prototype write-up](RAW-113-prototype.md)), and RAW-113
and RAW-125 were closed. It turned up RAW-137 (Default renders Fujifilm high-ISO photos too dark), which relates to
RAW-125.

| Ticket | Type | Label | Blocked by |
|---|---|---|---|
| RAW-125 Color profiles: prototype a Classic Chrome fit | Subtask of RAW-113 | ready-for-agent | — |
| RAW-126 Profiles: read and render DCP camera profiles | Task | ready-for-agent | — |
| RAW-127 Profiles: read the look chosen at capture from maker notes | Task | ready-for-agent | — |
| RAW-128 Profiles: fitting tool for camera-matching profiles | Task | ready-for-agent | RAW-125, RAW-127 |
| RAW-129 Profiles: bundled Fujifilm camera-matching profiles | Task | ready-for-agent | RAW-125, RAW-128 |
| RAW-130 Fujifilm: render the missing film simulations with X RAW STUDIO | Subtask of RAW-129 | ready-for-human | — |
| RAW-131 Presets: Fujifilm Grain Effect presets | Task | ready-for-agent | RAW-128, RAW-130 |
| RAW-132 Import: Camera Settings profile for RAW files | Task | ready-for-agent | RAW-127, RAW-129 |
| RAW-133 Profiles: bundled Nikon camera-matching profiles | Task | needs-triage | RAW-125, RAW-129 |
| RAW-134 Profiles: bundled Sony camera-matching profiles | Task | needs-triage | RAW-125, RAW-129 |
| RAW-135 Profiles: bundled Canon camera-matching profiles | Task | needs-triage | RAW-125, RAW-129 |

The Tasks also relate to RAW-113; RAW-126 relates to RAW-56, whose camera-matching part it completes. RAW-40 and
RAW-56, which the code had already done, were closed with a comment each.

**On hold since 2026-10-20:** RAW-127 to RAW-135. Lightroom beat decision 8's bar on the photos compared, so Ted held
the build, and will later look into a platform-independent RAW parser to replace Apple's RAW engine. Their only label
is now `on-hold`, as on RAW-112; the table shows the labels they had before. RAW-126 (DCP) and RAW-137 (the high-ISO
bug) aren't held.
