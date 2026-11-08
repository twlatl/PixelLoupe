# Keep only a seed for each Remove spot, and cache its fill at a fixed working resolution

Remove (RAW-260) fills a painted area with new pixels, either by patch synthesis (Use generative AI off) or with an
on-device Core ML inpainting model (on). Refresh asks for a different fill of the same area. Unlike a subject matte
(ADR 0003), a fill doesn't simply follow from the file and the settings, because any number of fills are
equally valid. Each fill still has to survive cache clears and look the same in the preview, thumbnails, the
loupe and exports.

So a Remove spot (`PhotoAdjustments.Spot`, kind `.remove`) stores:

- its stroke (the painted path and brush size, refined by Detect objects into a mask), and
- a **variation seed**, plus which engine made the fill (patch or generative) and the engine's `version`.

Refresh just picks a new seed. The fill's pixels are never written to the catalog.

**Both engines must be deterministic for a given seed**:

- Patch fill uses the seed for every random choice it makes.
- The generative model always runs on the same compute units (`cpuAndGPU`, fp32, never the Neural Engine), with
  its noise and any random crops taken from the seed.

**A fill is made at a fixed working resolution and cached.** The engine fills the spot's bounding box (plus a
margin for context) taken from the full-resolution frame and scaled to at most 1024 px on its long edge. That one
result is scaled into every view, so the preview at display resolution and a full-resolution export show the same
fill. Fills are cached in memory and on disk in `~/Library/Caches/<bundle id>/RemoveFills`, compressed (LZFSE),
keyed by a SHA-256 of the decoded file (as for mattes, including whether it's the Smart Preview), the geometry
settings that move pixels around the frame (Lens Corrections, Rotate/Flip, Transform), the stroke, the seed, the
engine and its version. Like mattes, fills are made before tone and color, so most edits never invalidate them.

Develop's preview doesn't wait for a fill: it shows the area unfilled (with a progress indicator on the spot's pin)
and draws again when the fill arrives. Rendering off the main thread (thumbnails, exports, Compare) waits for it.

## Why

- **The catalog stays small and portable.** A fill can be as big as a thumbnail or bigger. Seeds are a few bytes,
  copy cleanly with settings, and don't go stale when the geometry changes.
- **It can be made again.** Losing the cache costs the time to fill again, not the user's result, because the
  same seed gives the same fill on the same Mac.
- **Every view matches.** Filling separately at each view's resolution would give different patches and model
  inputs, so the export wouldn't match what the user approved in Develop.

## Considered

- **Storing the fill's pixels** with the photo's edits or in a sidecar: always exact on every machine, but a
  megabyte or more per spot in `adjustmentsData`. It would go into copied settings and presets and need throwing
  away whenever the geometry changed.
- **Filling at full resolution every time:** sharpest result, but slow for a first Remove on a large file, and a
  photo with only a Smart Preview couldn't match its export.
- **CPU-only inference** for identical pixels on every Mac: several seconds per large Remove.

## Costs

- **The same seed can fill slightly differently on another Mac** (a different chip or OS version changes the
  GPU math). We accept this: a catalog moved to another Mac may show small changes in generative fills.
- **A photo whose original is offline fills from its Smart Preview** (a different key), so its fill can differ
  from the original's.
- **Very large Removes are a little soft**, because they're filled at 1024 px and scaled up.
- **The engine `version` has to change** whenever either engine's output changes (a new model, a patch-fill
  tweak). Old fills are then made again and may look different, so bump it only on purpose and say so in the
  release notes.
- **The generative model is downloaded the first time it's used.** Until it has downloaded, generative Remove
  spots render with patch fill and say so in the panel.
