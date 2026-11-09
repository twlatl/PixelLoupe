# PixelLoupe

A Mac photo library and RAW editor modelled on Adobe Lightroom Classic. These are the terms the code and
tickets use. Where Lightroom has a name for something, PixelLoupe uses it.

## Publishing

- **Publish Service**: a configured place that photos are published to and kept up to date: a folder on a
  Hard Drive, or one Flickr account. It has a Description (its name in the sidebar), an account, and
  settings. Two Flickr accounts are two services. In code it's `PublishService`, and its kind is
  `PublishService.Kind`. *Not* a service type: the Publishing Manager's Add button picks the kind.
- **Publishing Manager**: the window where services are added, set up, and removed (Window ▸ Publishing
  Manager…).
- **Publish Settings**: a service's settings: the Export settings every published photo is rendered with,
  plus what only publishing has, such as the title source and Flickr's Privacy & Safety.
- **Published Photo**: a photo's place in one service (`PublishedPhoto`): added, published (where to, and
  when), or waiting to be removed. A photo can be in several services.
- **New / Modified / Published / Deleted**: the four groups a service's photos are shown in. They're
  derived from the Published Photo and the photo (see `docs/adr/0002-publish-tracking.md`):
  - *New*: added but not yet published.
  - *Modified*: the photo's pixels or published metadata changed since it was published.
  - *Published*: up to date.
  - *Deleted*: taken out of the service, or deleted from the catalog, and waiting to be removed from
    the service.
- **Publish**: the one action that sends a service's New and Modified photos and removes its Deleted ones.
  Nothing is published automatically.
- **Re-Publish**: publishing a Modified photo again over its earlier copy. On Flickr, a pixel change
  replaces the photo, and a metadata-only change just updates its title, description and tags, so comments
  and favourites survive.
- **Publisher**: the code that sends photos to one kind of service (`Publisher`; `HardDrivePublisher`, and
  later a Flickr publisher).

## Previews

- **Thumbnail**: the 768 px sRGB JPEG of a photo in the package's `Thumbnails` folder that the grid,
  filmstrip and every small view draw (`ThumbnailStore`). An unedited photo's comes from the file's embedded
  preview, unless it has a Standard Preview; an edited one's is rendered through Develop.
- **Build Previews**: Import ▸ File Handling's choice of how the imported photos' previews are made
  (`ImportPreviewLevel`), with Lightroom's names:
  - *Minimal*: the embedded preview as the thumbnail; nothing else. The default.
  - *Standard*: for camera RAW files, a Standard Preview, and a thumbnail rendered from it, built in the
    background after the import.
- **Standard Preview**: a 2560 px Display P3 rendering of a RAW photo with its Develop settings, in the
  package's `Previews` folder (`StandardPreviewStore`). The loupe, Develop, Compare and Survey show it while
  the full render runs. An edit makes it *stale* (renamed `.stale`, never shown) until it's drawn again about
  two seconds after the last change. *Not* a Smart Preview, which stands in for a missing original. *Not* a
  1:1 preview, which PixelLoupe doesn't have yet.
- **Smart Preview**: a 2560 px Linear DNG stand-in for an original that's offline, so the photo can still be
  edited (`SmartPreviewStore`; see `docs/design/RAW-85-smart-previews.md`).
