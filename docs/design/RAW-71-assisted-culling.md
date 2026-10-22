# RAW-71: Assisted Culling (design)

**Status:** design agreed on 2026-10-21. Thresholds and score scales are tuned against real RAW files during the
engine work, so treat any numbers here as starting points.

## Goal

Help the photographer get from a shoot to a short list fast. PixelLoupe scores each photo for focus, eyes and obvious
technical failures, splits the current source into **Selects** and **Rejects** by criteria the user sets, and can turn
that split into Pick/Reject flags and stacks.

Not in scope: a People view, score fields in smart collections, analyzing at import, and keyboard shortcuts (Lightroom
has none to match).

## Analysis

- **When:** on demand for the current source. The panel shows **Analyze** for a source with unanalyzed photos; it
  queues a background job (same pattern as `ThumbnailMaintenance` / `SmartPreviewBuilder`) with progress in the panel.
  **Re-analyze** in the panel's menu re-scores the current source.
- **What is scored:** the unedited original with default rendering. Edits never trigger re-analysis. Virtual copies
  use their master's scores. Videos are skipped (they appear only under All).
- **Sources** (revised while building the engine; see "Engine notes"):
  - The unedited photo is rendered from the original, or its Smart Preview when the original is offline, twice: an
    **overview** 1024 px on the long edge and a **detail** render 2560 px on the long edge.
  - On the overview: faces (Vision face rectangles), the subject (attention saliency), documents
    (`CalculateImageAestheticsScoresRequest.isUtility` plus text recognition), exposure and misfires.
  - On the detail render: each face's eye landmarks (from a crop around the face) and focus of the subject region and
    of each face's eyes.
  - With neither the original nor a Smart Preview, everything but focus is measured on the 768 px thumbnail; focus is
    stored as **unknown** and measured when the original or a Smart Preview can be read again.
- **Stored on `Photo` (model v17):** subject focus, eye focus, least and most open eyes, faces counted, exposure
  issue, misfire, document, Vision's aesthetics score (for picking the top of an Auto Stack), whether focus is still
  to be measured, and the analysis version. Scores are stored raw (0–1, -1 unknown), so moving a slider only changes
  the predicate; nothing is re-analyzed. A photo whose analysis version is older than the app's counts as unanalyzed.
- Detected faces are **not** saved as `FaceRegion`s; those belong to people tagging.

## Criteria

All checked Select criteria must pass, and any checked Reject criterion that hits sends the photo to Rejects. Reject
wins over Select.

| Criterion | Rule |
|---|---|
| Subject Focus | subject focus ≥ slider (Soft ↔ Sharp, default midpoint). Unknown passes. |
| Eye Focus | eye focus ≥ slider. Unknown passes. No faces passes unless "only photos with eyes detected". |
| Eyes Open | every face above ~3% of frame width has open eyes; small background faces ignored. Ambiguous (confidence in the middle band, or faces disagree) goes to Selects only with "Select ambiguous photos". No faces passes unless "only photos with eyes detected". |
| Exposure Issues | too much of the frame clipped at either end, or mean luminance far from mid-grey. Fixed thresholds. |
| Misfires | almost no detail (lens cap, black frame, pocket shot) or heavy whole-frame blur. Fixed thresholds. |
| Documents | Vision's utility-image flag. |

## Panels

Two sections in the Library inspector, after Histogram:

- **Assisted Culling:** the criteria above; **Review** (Selects / Rejects / All), which ANDs a predicate into the
  grid's filter and resets to All when the source changes (unanalyzed photos show only under All); **Apply**, which
  writes Pick/Reject flags in one undo step and leaves already-flagged photos alone; **Auto Stack…**. Settings are
  app-wide in user defaults.
- **Assisted Culling Info:** for the target photo, the verdict (Select/Reject) and which criterion rejected it, the
  three scores, faces counted, and the exposure/misfire/document results. "—" when not analyzed, with a note when the
  photo is offline.

## Auto Stack

A sheet with **By Capture Time** (gap slider) or **By Visual Similarity** (strictness slider) and a live count of the
stacks it would make. Acts on the selection when two or more photos are selected, otherwise the source; skips photos
already stacked; creates real `PhotoStack`s in one undo step; the best-scoring photo goes on top, otherwise the
earliest. Similarity uses Vision feature prints computed from thumbnails when the sheet opens, kept in memory only.

## Engine notes (RAW-169)

Measured on 211 RAW files (Sony ARW, Fujifilm RAF, DNG) from the sample library; numbers are starting points.

- **Focus at 2560 px, not full resolution.** A Smart Preview is 2560 px, so measuring every photo at that size makes a
  photo score the same whether its original is online or not, and makes "sharp" mean sharp on a large display rather
  than at 100%. It's also much cheaper: about 1.1 s per 24–40 MP RAW file for the whole analysis.
- **Focus measure.** Laplacian variance (edge energy) ranked smooth but sharp subjects (a product on a lightbox) as soft.
  The measure is instead the mean absolute Laplacian over the mean gradient, which tracks edge width rather than
  contrast or texture, after a light blur. It's taken in 32 px tiles (16 px for eyes) that have real edges, averaging
  the crispest tenth, so smooth areas don't count and a shallow focus plane inside a big subject box isn't averaged
  away. Sharp frames measure about 0.9–1.5, shallow depth of field 0.55–0.9, a slightly soft low-light portrait 0.77,
  sharp frames blurred by σ 1.4 px 0.4–0.73 and by σ 2.8 px 0.1–0.47, and a badly misfocused frame 0.2. Scores map
  0.25 → 0 and 0.85 → 1, so the default slider (0.5) sits at 0.55: σ 2.8 blur fails and shallow depth of field passes.
- **Misfires.** Black frames, near-uniform frames, and frames with nothing sharp anywhere at 2560 px (under 0.3). An
  earlier "little detail" rule flagged minimal product shots on white backgrounds, and whole-frame blur can't be told
  at overview size (every frame has a few crisp tiles at 1024 px).
- **Eyes.** At 1024 px Vision returns collapsed eye outlines for faces under about 60 px wide, so landmarks are read
  from a crop of the 2560 px render around each face. Faces whose eyes still can't be made out (profiles, backs of
  heads) aren't counted. Openness is the eye outline's height over width: 0.07 is closed, 0.15 and over is open
  (smiling eyes measure about 0.15–0.21, wide open about 0.32).
- **Documents.** Vision calls product shots utility images too, so a document also needs three or more lines of text
  covering 5% of the frame.

## Delivery

RAW-71 is a Story with four sub-tasks, each a stacked PR against `main`:

1. Analysis engine and stored scores (RAW-169).
2. Assisted Culling panel, Review filter and Apply (RAW-170).
3. Assisted Culling Info panel (RAW-171).
4. Auto Stack (RAW-172).
