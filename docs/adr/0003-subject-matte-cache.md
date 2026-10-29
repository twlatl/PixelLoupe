# Keep the subject Vision finds in a disk cache, keyed by file and geometry, not in the catalog

Subject and Background masks (RAW-192) need the photo's subject, which Vision's
`VNGenerateForegroundInstanceMaskRequest` finds in about a third of a second on a 1536-pixel image. That's too slow
to do on every render, so `SubjectMatteStore` finds it once and keeps the matte (8-bit gray, 1536 px on the long
edge):

- in memory, for the last couple of dozen photos, and
- on disk in the app's caches (`~/Library/Caches/<bundle id>/SubjectMattes`), compressed (LZFSE), one file per key.

The key is a SHA-256 of the decoded file's path, whether it's the Smart Preview, and the settings that move pixels
around the frame masks are placed on: Lens Corrections, Rotate/Flip and Transform. Nothing else is in the key, so
tone and color edits never find the subject again. A photo's mask only ever stores its own Feather and Edge.

Rendering off the main thread (thumbnails, exports, the Navigator, Compare) waits for the subject, finding it then
if it must, so what's written always has the mask. Develop's preview draws on the main thread, so it doesn't wait:
it draws without the mask, the subject is found in the background, and `SubjectMatteStore.didFind` makes it draw
again (and the Masking panel says "Finding the subject…" meanwhile, or "No subject found").

## Why

- **The catalog stays small and portable.** A matte is about as big as a thumbnail. Stored in `adjustmentsData`
  it would make every photo with a subject mask a megabyte bigger, travel with copied settings and presets to
  photos it doesn't belong to, and go stale when the geometry changed.
- **It can always be found again.** The matte follows from the file and the geometry, so losing the cache (it's
  in Caches, which macOS may clear) only costs the time to find it again. Pasting settings onto another photo
  finds that photo's subject without anything to invalidate.
- **Found on the frame masks use, before tone.** Masks are placed on the frame after Lens Corrections and
  Transform and before the crop, so that's what Vision looks at; a brighter or warmer edit doesn't change what
  the subject is.

## Costs

- A photo whose original is offline finds its subject again from its Smart Preview (a different key), and the
  two mattes can differ slightly.
- An export of a photo whose subject hasn't been found yet waits about a third of a second per photo for it.
- The matte is found at 1536 px and scaled, so a full-resolution export's subject edge is a little soft; Feather's
  default softens it more anyway.
- The `version` in the key has to change if the way the subject is found changes, or old mattes would be kept.

## People (RAW-213)

Portrait Lighting needs the people in a photo, not every foreground subject (a dog or a chair would stay lit on a
black Stage). `SubjectMatteStore` finds them the same way, as a second kind of matte: Vision's
`VNGeneratePersonSegmentationRequest` at `.accurate`, scaled to the 1536-pixel detection image, refined onto the
photo's edges like Rim Light's subject, and kept in the same memory and disk caches. The kind is part of the key
only for people, so subject mattes kept before people were found are still used. A mask with less than 0.1% of the
frame in it counts as no person.

## Faces (RAW-215)

Studio and Contour need each face's place, tilt and turn. `FaceStore` finds them with Vision's
`VNDetectFaceLandmarksRequest` on the same 1536-pixel detection image and keeps them the same way: in memory, and on
disk as small JSON files in `~/Library/Caches/<bundle id>/Faces`, under the subject's key plus `-faces`. They're found
only when Studio or Contour renders, never on import, and nothing goes in the catalog (Assisted Culling's faces are
stored only as scores). Turn and tilt come from the landmarks (where the nose sits across the face, the line through
the eyes) rather than Vision's yaw and roll, so their direction in the frame is unambiguous.
