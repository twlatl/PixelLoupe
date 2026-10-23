# Track published photos with a PublishedPhoto per photo and service, and derive their state

A publish service (RAW-175) has to know which of its photos are new, which have changed since they were
published, which are up to date, and which were taken out and still have to be removed from the service.
Model v18 adds two entities:

- `PublishService` is a configured service: its kind (Hard Drive, Flickr), Description, account, and its
  `PublishSettings` as JSON. Each Flickr account is a separate service.
- `PublishedPhoto` is a photo's place in one service: when it was added, and once published, the service's
  ID for it (a Flickr photo ID, or the file's path), its URL, when it was published, and a fingerprint of
  the metadata that went with it. It can also say that it's waiting to be removed, and why the last
  publish failed.

The state is **derived**, not stored:

| State | When |
|---|---|
| New | not yet published |
| Modified | `Photo.editDate` is later than `publishedDate`, or the metadata fingerprint differs |
| Published | otherwise |
| Deleted | taken out of the service (`isRemovalPending`), or the photo was deleted from the catalog |

## Why

- **Nothing to keep in sync.** A stored "needs re-publish" flag would have to be set by every edit,
  keyword, rating and metadata change, including undo, Lightroom import and sync, and one missed path
  leaves a stale photo looking published. Comparing against what was published can't drift.
- **Pixels and metadata are told apart.** `editDate` is set only when a photo's pixels change
  (Develop, Edit In). The metadata fingerprint is a SHA-256 of the fields that are published: metadata
  fields, export keywords, rating and location. Knowing which one changed lets Flickr replace the photo
  only when its pixels changed, and otherwise just update its title, description and tags.
- **Deleting a photo keeps its published copy removable.** `PublishedPhoto.photo` uses Nullify, so the
  entry outlives its photo and shows in Deleted. An entry that was never published is dropped instead.
  `fileName` is kept on the entry so it can still be named.
- **Publishing a photo isn't an edit.** Publish writes its bookkeeping with undo registration off. The
  published date is when the publish *started*, so an edit made while it runs leaves the photo Modified.

## Costs

- Modified and Published can't be told apart in a fetch predicate. The Library computes them in memory
  for the selected service's entries (RAW-179). That's fine for a service's hundreds or thousands of
  photos, but it isn't a predicate over the whole catalog.
- Changing a service's settings doesn't mark its photos Modified. Lightroom asks whether to re-publish
  everything when settings change; that belongs with the Publishing Manager (RAW-178).
