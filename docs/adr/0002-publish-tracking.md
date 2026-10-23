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
- Changing a service's settings doesn't mark its photos Modified by itself. When you save settings that
  change how photos are rendered, named or titled, the Publishing Manager (RAW-178) asks whether to
  Re-Publish All, as Lightroom does. Re-Publish All sets each published date to `distantPast`, so every
  photo counts as edited since it was published. Privacy and safety changes don't ask: they only apply
  to photos published from then on.
- Mark to Republish in a service's menu (RAW-184) does the same as Re-Publish All. Reset Export Status does the
  opposite: it clears each entry's published date, remote ID, URL, fingerprint and error, so every photo is
  New, and drops entries waiting to be removed. It doesn't touch the service itself, which is why it asks
  first: anything still there is uploaded again by the next Publish.

## Albums (RAW-185)

Model v20 adds `PublishAlbum` for a Flickr service's albums. An album is a group of the service's
`PublishedPhoto`s, not a container of its own: each photo is uploaded once however many albums hold it,
and taking it out of an album leaves it in the photostream. A smart album's photos are whatever matches
its rules, and they join the service at the next Publish.

An album's Flickr state is derived the same way as a photo's: it keeps the name, description and photo
IDs it last sent, and has changes to publish when those differ from what it holds now. Publish sends the
photos first, then the albums, since a Flickr album can only be made with a photo that's already there.

**Publish only adds and removes this catalog's photos** (`photosets.addPhoto` / `removePhoto`). It never
sets an album's whole list (`photosets.editPhotos`), because that would drop photos someone added on
flickr.com, or that another catalog publishing to the same account added. For the same reason an album
deleted here, or left with none of this catalog's photos, only loses this catalog's photos; it isn't
deleted on Flickr. The cost is order: Flickr keeps photos in the order they were added, and the cover is
the first photo, chosen when the album is made.
