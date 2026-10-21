# PixelLoupe
A raw photo editor and catalog for the Mac, modeled on Lightroom Classic. Free and open source.

Found a bug or want a feature? [Open an issue](https://github.com/twlatl/PixelLoupe/issues/new/choose). Want to help with
the code? Read [CONTRIBUTING.md](CONTRIBUTING.md) and [SKILLS.md](SKILLS.md), the project's rules.

## Requirements

- macOS 27 or later
- Xcode 27.2 or later, with the Metal Toolchain (Photo Merge's Core Image kernels need it; Xcode offers to install it, or
  run `xcodebuild -downloadComponent MetalToolchain`)

## Building

Open `PixelLoupe.xcodeproj` and run the **PixelLoupe** scheme, or from the command line:

```sh
xcodebuild -project PixelLoupe.xcodeproj -scheme PixelLoupe -destination 'platform=macOS' test
```

The JPEG XL encoder Smart Previews use, libjxl, is checked in already built, as
`Packages/JXLEncoder/libjxl.xcframework`, so building needs nothing else. `Scripts/build-libjxl.sh` rebuilds it from
the pinned libjxl release (it needs CMake: `brew install cmake`). The build is reproducible: with the same Xcode it
gives the same bytes, so the checked-in copy can be verified with `git diff --stat` after running it.

## Updates

PixelLoupe updates itself with [Sparkle](https://sparkle-project.org). **PixelLoupe ▸ Check for Updates…** checks now; at
the second launch Sparkle asks whether to check automatically (daily) and whether to download and install updates by
itself, and **Settings ▸ General** changes those answers later. An update window shows what's new in the version on
offer (its GitHub release notes) before anything is installed. Development builds don't check (Debug builds would
always find the release newer), and neither do the tests.

The app looks for `appcast.xml` on the latest published release
(`https://github.com/twlatl/PixelLoupe/releases/latest/download/appcast.xml`, `SUFeedURL`). Only stable releases are
offered: drafts and prereleases never are. Sparkle installs an update only if it's signed with PixelLoupe's EdDSA key
(whose public half is `SUPublicEDKey` in `Config/Info.plist`) and with the same Developer ID as the app.

## Releasing

Pushing a version tag builds a release on GitHub (`.github/workflows/release.yml`): a Release build signed with Developer
ID, in a disk image (`PixelLoupe-1.2.0.dmg`, with an Applications shortcut) that is notarized and stapled, so it opens
without warnings, and signed for Sparkle. It's attached, with its SHA-256 checksum, its `.appcast.json` (version, size
and update signature) and notes generated from the merged pull requests, to a **draft** release.

```sh
git fetch origin && git tag v1.2.0 origin/main && git push origin v1.2.0
```

Check the draft on GitHub and edit its notes: they're what the update window shows. **Publishing it offers the update to
everyone**: the Publish Appcast workflow (`.github/workflows/appcast.yml`) writes `appcast.xml` from the release's notes
and the `.appcast.json` (`Scripts/appcast.sh`) and attaches it to the release, usually within a minute. Editing a
published release's notes writes it again.

The tag sets the app's version (1.2.0). A tag with a suffix, such as `v1.2.0-beta.1`, makes a prerelease: the disk image
is named after the whole tag, and the app says 1.2.0. The build number is the time of the build (UTC, to the minute,
such as `202610181432`), so each build's is higher than every earlier one's.

**One-time setup:** `Scripts/setup-release-secrets.sh` walks through exporting the Developer ID Application certificate,
making an App Store Connect API key (Developer role) for notarizing, and making Sparkle's EdDSA update key (in your
login keychain, account `net.pixegen.PixelLoupe`; it adds the public half to `Config/Info.plist`, to commit). It stores
them as the repository's Actions secrets (`DEVELOPER_ID_P12`, `DEVELOPER_ID_P12_PASSWORD`, `NOTARY_KEY_P8`,
`NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`, `SPARKLE_ED_PRIVATE_KEY`). Run it again to replace any of them, for example when the
certificate is renewed; steps whose secrets are already set can be skipped. Only the release workflow reads them. It
runs only for tags, and it uses no third-party actions. **Back up the Sparkle key** (`generate_keys --account
net.pixegen.PixelLoupe -x <file>`, from Sparkle's `bin` folder): if it's lost, installed copies can't be updated.

**On a Mac:** `Scripts/release.sh 1.2.0` does the same build into `build/release`, signing with the Developer ID
certificate in your keychain. The GitHub secrets don't reach it: it notarizes with a notarytool keychain profile named
`PixelLoupe` (the setup script offers to save one, or run `xcrun notarytool store-credentials PixelLoupe --key
AuthKey_<KEY ID>.p8 --key-id <KEY ID> --issuer <ISSUER ID>`). `NOTARY_PROFILE` names a different profile, and
`NOTARY_KEY`, `NOTARY_KEY_ID` and `NOTARY_ISSUER` give it an API key instead. It signs the update with the Sparkle key in
your keychain (or `SPARKLE_KEY_FILE`), and checks both before building, stopping if either is missing or the Sparkle key
isn't `SUPublicEDKey`'s. `NOTARIZE=0` builds a signed disk image without notarizing it (or signing it for Sparkle), and
`SIGNING_IDENTITY=-` an ad hoc signed one, to check the packaging without a certificate.

Release builds leave out Sparkle's XPC services (only sandboxed apps use them) and sign its helpers with the app's
Developer ID, as notarization requires. The disk image is APFS with LZFSE compression, as Sparkle recommends.

## Architecture

- **UI:** AppKit, built in code (no storyboards). The photo grid is an `NSCollectionView` with layer-backed
  cells composited by Core Animation/Metal. Develop renders through Core Image on an `MTKView`.
- **RAW:** Apple's RAW pipeline via `CIRAWFilter`. Grid thumbnails are generated once at import with ImageIO
  and re-rendered when a photo is edited.
- **Develop:** non-destructive edits stored per photo as JSON (`Photo.adjustmentsData`). Exposure, white
  balance, noise reduction and sharpening run inside `CIRAWFilter` for RAW files (Core Image filters for other
  formats). Tone, levels, curves, color grading, selective color and black & white are folded into a single
  3D color lookup table, which also carries Whites, Vibrance and Saturation. Texture, Clarity and Dehaze (the
  Adjust panel's Presence section) are Core Image filters on the GPU. The preview renders at display resolution on an `MTKView`.
- **Catalogs:** each catalog is a `.pixelloupe` package containing its own Core Data (SQLite) store,
  `Catalog.plist` settings and a `Thumbnails` cache. Catalogs either copy imported photos into a storage
  folder organized as `YYYY/MM-DD`, or reference photos where they already are. Catalogs made before the app
  was renamed (`.lightloupe` from LightLoupe, `.rawloupe` from RawLoupe) still open; they aren't renamed.
- **Earlier names:** PixelLoupe was LightLoupe, and RawLoupe before that. On first launch it copies the old
  preferences (`net.tedlee.LightLoupe`, then `net.tedlee.RawLoupe`) without overwriting any already set, and
  copies `~/Library/Application Support/Pixegen/LightLoupe` (presets and profiles) to `Pixegen/PixelLoupe`.
- **Concurrency:** Swift 6 with main-actor default isolation. Import work (metadata, copying, thumbnails)
  runs in `@concurrent` functions and inserts in batches on a background context.

| Folder | Contents |
| --- | --- |
| `PixelLoupe/App` | Entry point, app delegate, main menu |
| `PixelLoupe/Catalog` | Catalog package format and Core Data stack |
| `PixelLoupe/Model` | Core Data model and managed object classes |
| `PixelLoupe/Import` | File discovery, metadata reading, import pipeline |
| `PixelLoupe/LightroomImport` | Lightroom Classic catalog reader, Lua parser and the import flow |
| `PixelLoupe/Thumbnails` | Thumbnail generation and caching |
| `PixelLoupe/Library` | Library module: sidebar, filter bar, grid, bottom toolbar |
| `PixelLoupe/Develop` | Develop module, adjustment model and render pipeline |
| `PixelLoupe/Develop/Panel` | Adjust panel and its controls |
| `PixelLoupe/Merge` | Photo Merge: the HDR and panorama merges, their sheets, and the Linear DNG writer |
| `PixelLoupe/ContactSheet` | Contact Sheet: its window, page layout, preview and PDF writer |
| `PixelLoupe/Windows` | Welcome, About, new-catalog and catalog windows |

## Keyboard shortcuts

| Key | Action |
| --- | --- |
| `G` / `D` | Library / Develop (also `⌘1` / `⌘2` and Lightroom's `⌥⌘1` / `⌥⌘2`) |
| `⌘3` | Map (also Lightroom's `⌥⌘3`; Lightroom has no single key for it) |
| `0`–`5` | Set rating; Photo ▸ Set Rating and the grid's right-click menu show the keys (a pill over the photos confirms each rating, flag and label applied: "Rating ★★★", "Flag Rejected", "Label ●") |
| `[` / `]` | Decrease / increase rating (each photo one star down or up) |
| `P` / `U` / `X` | Flagged / Unflagged / Rejected |
| `6` / `7` / `8` / `9` | Color label red / yellow / green / blue; press the same key again to clear it (purple has no key, as in Lightroom: Photo ▸ Set Color Label) |
| Shift-click | Select every photo between the last one clicked and this one (grid and filmstrip); `⌘⇧`-click adds the range |
| `E`, `Return` or double-click | Enlarge the photo to fill the grid area (`Return` again or `Esc` to go back) |
| `Z` or `Space` | Toggle zoom: between the Navigator's fit choice (FIT or FILL) and its zoom (1:1 or a ratio); from the grid it enlarges the photo zoomed in |
| `F` | View the photo full screen (`Esc` returns to the grid) |
| `←` / `→` | Previous / next photo while enlarged, full screen or in Develop (filmstrip); next candidate in Compare; next photo in Survey |
| `=` / `-` | Larger / smaller thumbnails |
| `⌘U` | Auto Light (Develop) |
| `⌘G` / `⇧⌘G` | Group the selected photos into a stack / unstack (Photo ▸ Stacking) |
| `S` / `⇧S` | Collapse or expand the stack of the selected photo / move the selected photo to the top of its stack |
| `⌘'` | Create Virtual Copy (Photo menu; a copy keeps the master's file but has its own edits, rating, flag, label and keywords) |
| `⌃H` | Photo Merge ▸ HDR… (the selected bracketed RAW photos) |
| `⌃⇧H` | Photo Merge ▸ HDR with Previous Settings: merges the HDR straight away with the last options, without the preview (hold Shift in the menu) |
| `⌃M` | Photo Merge ▸ Panorama… (the selected overlapping RAW photos) |
| `⌃⇧M` | Photo Merge ▸ Panorama with Previous Settings: merges a panorama straight away with the last options, without the preview (hold Shift in the menu) |
| `⌘E` / `⌥⌘E` | Photo ▸ Edit In: edit the selected photos in the primary / additional external editor (Settings ▸ External Editing) |
| `⌘[` / `⌘]` | Rotate left (counterclockwise) / right (clockwise) |
| `⇧⌘R` | Revert to Original (selected photos) |
| `⇧⌘C` / `⇧⌘V` | Copy Settings (the selected photo's) / Paste Settings (a copied preset or photo's settings onto every selected photo) |
| `⇧⌘I` | Import Photos: opens the import window (see [Importing photos](#importing-photos)); in it, `Space` checks or unchecks the selected photos, and while a photo is enlarged `←` / `→` step and `Esc` returns to the grid |
| `⌘F` | Show the Library Filter bar's Text mode (alongside any other active modes) and put the cursor in its search field |
| `` ` `` | Show or hide the Develop loupe (hold and click to place it) |
| `⌘,` | Settings (General: confirm when quitting; Appearance: appearance, matte color and Monochrome Mode; Import: JPEG sidecars and opening the import window when a card is inserted; Displays: the secondary window's display; External Editing) |
| `⌘Q` | Quit, after asking "Are you sure you want to quit?" (Return quits; turn the question off in Settings ▸ General or with its Don't ask again box) |
| `⌃⌘F` | Enter or exit full screen for the app window |
| `F6` | Show or hide the filmstrip |
| `⌘F11` / `⇧⌘F11` | Show or hide the secondary window / make it full screen, on the display chosen in Settings ▸ Displays (also the toolbar's display button and Window ▸ Secondary Display; the button shows when more than one display is connected) |
| `⇧G` / `⇧E` / `⇧C` / `⇧N` | Secondary window: Grid / Loupe – Normal / Compare / Survey (opens it if it's hidden). Window ▸ Secondary Display also has Loupe – Live (the photo under the pointer in the main window) and Show Second Monitor Preview (while it's full screen). In the secondary window `=` / `-` size its own thumbnails, `E` or `Return` switches views, `←` / `→` step through photos (or candidates in Compare) and `Esc` returns to the grid |
| `⇧⌘Return` | Secondary window: Loupe – Locked (keeps the photo on show until you choose another view; again to unlock) |
| `R` | Crop & Straighten (Develop); in the crop tool `Return` applies, `Esc` cancels, `X` flips the orientation |
| `J` | Show or hide shadow and highlight clipping on the Develop preview |
| `Y` / `⌥Y` / `⇧Y` | Develop's Before/After (View ▸ Before/After): the photo before its edits left of / above the edited photo, or Split Screen (one photo, before left of a line down the middle and after right of it); the same key again goes back to the edited photo |
| `\` | Library: show or hide the Library Filter bar (View ▸ Hide Filter Bar; hiding it keeps its filters, and the filmstrip shows "42 of 310 photos" while they leave photos out). Develop: Before Only, the photo before its edits; `\` again shows it edited |
| `W` | White Balance Selector: click something that should be neutral gray (Develop ▸ Adjust) |
| `⌘K` | Add Keywords: the cursor in the right sidebar's Keywords field (in Library; shows the sidebar if hidden) |
| `Tab` | Show or hide both sidebars (in Develop: the folder sidebar and the adjustment panel) |
| `⌫` | Remove Photo (the selected photos in the grid, or the photo shown): remove from the catalog, or also move to the Trash |
| `⇧⌫` | Remove Selected Photo (every selected photo) |
| `⌥⇧⌘⌫` | Remove and Trash Photo (remove the selected photos and move their files and sidecars to the Trash) |
| `⌘⌫` | Delete Rejected Photos (shows the rejected photos in the catalog or folder, then removes or trashes them) |
| `⌘N` | New Collection (Library menu; `⌥⌘N` is now New Catalog) |
| `⇧⌘E` | Export… |
| `⌥⇧⌘E` | Export with Previous |
| `B` | Add the selected photos to the target collection (or remove them if they're all in it) |
| `C` | Compare the two selected photos (or the selected photo and the next); `C` or `Esc` to leave |
| `N` | Survey: every selected photo side by side; `N` or `Esc` to leave |
| `⌘Return` | Impromptu Slideshow of the selected photos (or every photo in the grid) on this display; `Esc` or `⌘Return` stops, `Space` pauses, `←` / `→` step |
| `⌥⇧⌘Return` | Slideshow on the secondary display while you keep working (again to stop) |
| `⌃⌥⌘C` | Contact Sheet: a window laying out the selected photos (or every photo in the grid) on pages, saved as a PDF with Generate… (see [Contact sheets](#contact-sheets)) |

Single-key shortcuts are ignored while typing in a text field.

In the Develop Adjust panel, double-click a slider's label, a color wheel or the curve to reset it.

The side panels' sliders (Develop, Crop, Lens, Masking, Retouch and the preset Amount) also reset when you double-click
the knob, and Option-dragging one moves it in large steps: a tenth of its range, counted from its default (so a −5…+5
slider such as Exposure steps by 1.00).

## Navigator and zoom

The top of the left sidebar shows the catalog's name and where its photos are kept, then the **Navigator**: the
selected photo with a white rectangle around the part the enlarged view or Develop shows (the whole photo when it
fits), which animates as you switch between fit and zoom. Above it are Lightroom's zoom
choices: **FIT** (the whole photo), **FILL** (the view filled, cropping the long side), **1:1** (actual pixels) and a
menu of other ratios (1:16 … 11:1). Choosing one in the Library grid enlarges the selected photo.

In the enlarged Library view and in Develop, a click on the photo switches between the fit choice and the zoom,
centered where you clicked. The pointer is a magnifying glass while the photo fits and a hand while it's zoomed; drag
to move around. Zooming in and out animates, in the view and in the Navigator. Click or drag in the Navigator's
preview to jump there. `Z` or `Space` does the same as a click. The zoom carries
over from photo to photo and between Library and Develop. In Develop, click-to-zoom works with the Adjust, Lens
Corrections and History tools (Crop, Masking and Spot Removal use clicks themselves; the Navigator still zooms there,
except Crop, which always shows the whole photo). Zoomed in with Spot Removal, the pointer is a hand too: drag off the spots
to move around, and click to place one. Zoomed views render only the part on screen, at full resolution.

## Appearance

**Settings ▸ Appearance ▸ Appearance** follows the system or sets Light, Gray or Dark. **Gray** is Aperture's look, in
between the other two: Light Mode's controls and text on mid-gray panels, toolbar and sidebars, with a black matte
behind photos. Choosing a theme (or macOS switching between Light and Dark) puts **Matte Color** back to the theme's own:
10% in Light, black in Gray, 85% in Dark. Move the slider to change it from there.

## Monochrome Mode

**Settings ▸ Appearance ▸ Monochrome Mode** (off by default) replaces the accent color on sliders, buttons, icons
(including the sidebar's folder, catalog and collection icons) and selection highlights with dark gray in Dark Mode
and black (#000000) in Light Mode and Gray, so nothing in the interface competes with the
colors in your photos. Colors that carry meaning (color labels, the rejected flag, curve channels) stay as they are.
Checkboxes, switches and focus rings have no color of their own to change; Monochrome Mode sets PixelLoupe's system
accent to Graphite for those (macOS's gray, the closest it offers), which macOS applies the next time PixelLoupe opens.

## Importing photos

File ▸ Import Photos… (`⇧⌘I`) opens the import window; dropping files or folders on a catalog window opens it with
them. Across the top: **FROM** (the source and its path), **Copy / Add** (copy into a destination, or add the photos
where they are), and **TO** (the destination and the folder the first photo will land in). Copy / Add and the
destination are remembered for each catalog; a managed catalog starts out copying into its storage folder
(`2026/10-15`), a referenced one adding in place.

The sidebar lists **Devices** (iPhones, iPads and cameras connected over USB, read with ImageCaptureCore, and memory
cards: any disk with a `DCIM` folder, with the camera that shot it and a **New**
badge when it has photos the catalog doesn't), **Volumes** and **Locations** (Pictures, Desktop, Downloads and the last
ten folders imported from) as folder trees, and **Choose Folder…**. Cards and removable volumes have an eject button.
**Include Subfolders** (on by default) decides whether a folder's subfolders are read too; **Eject After Import** (off
by default) ejects a card once all its checked photos have come across. Choosing a source reads its photos and videos
without importing anything, and shows the count on its row. Photos on a card are always copied (Add is dimmed, and
choosing it says why: the catalog would point at a card that's about to be ejected). Ejecting the card being shown, or
unplugging the device, empties the grid. With Settings ▸ Import ▸ **Open the import window when a
memory card is inserted** (off by default), inserting a card brings PixelLoupe forward with the card chosen. A phone's or camera's
photos show their thumbnails from the device; importing downloads the checked ones to a temporary folder, imports
them as copies, then removes the downloads. A locked iPhone asks to be unlocked (and to trust this Mac) first.

The grid numbers the photos, sorted by **Capture Time**, **File Name** or **File Type** (the button beside the sort pop-up flips between ascending and descending), and can show **All Photos**,
**New Photos** (not already in the catalog), or **Destination Folders** (in a section for each folder they'll be copied
into). New photos start checked; ones the catalog already has show **In Library** and can't be checked (for Copy, the
same name, size and capture time; for Add, the same file). `Space` checks or unchecks the selected photos, as does clicking the checkbox of any one of several selected photos; Shift-clicking a checkbox gives every photo between it and the last checkbox clicked that one's state (uncheck one, Shift-click another, and all between are unchecked). Double-click a
photo, or click the loupe button, to see it filling the grid's space; `←` / `→` step and `Esc` or a double-click goes
back. The right panel's **Destination** section sets the folder, an optional subfolder, how photos are organized (**By
Original Folders**, recreating the folders they're in below the source chosen, such as `DCIM/100MSDCF` on a card; **By
Date**; or **Into One Folder**) and, for By Date, the **Date Format** (`2026/2026-10-15`, `2026/10-15`, `2026/10/15`,
`2026-10-15` or `2026/October/15`), taken from each photo's capture date.

The right panel's **File Handling** section:
- **Build Smart Previews** (off): once the import is in, the photos get Smart Previews in the background, so they can
  be edited while their originals are offline (as Library ▸ Previews ▸ Build Smart Previews does)
- **Don't Import Suspected Duplicates** (on by default; turned off, photos in the library can be checked and imported again)
- **Don't Import Rejected Images** (files rated as rejected, `xmp:Rating` −1, can't be checked)
- **Make a Second Copy** (Copy only: a backup of each file in an "Imported on 2026-10-15" folder in the chosen folder)
- **Add to Collection** (an existing collection, or a new one; left unnamed, it's "Import 2026-10-15")

**File Renaming** (Copy only) names the copies by a template: Date - Filename (`2026-10-15-DSC00112.ARW`),
Filename, Shoot Name - Sequence (`California Adventure-0001`), Custom Text - Sequence, Custom Text - Filename or Date -
Sequence, with a Start Number and Extensions (Leave As-Is, lowercase, UPPERCASE). Shoot Name follows the destination's
subfolder until it's typed; the Example line shows the first checked photo's new name; sidecars follow their photo's
new name, and second copies keep the original names.

**Apply During Import** sets a **Develop Settings** preset (applied to each photo it suits, as in Develop), a
**Metadata** preset and **Keywords** (completed from the catalog's keywords). A file's own rating comes in too: stars as
its rating, −1 as Rejected. All of these except the keywords are remembered for each catalog.

The **Metadata** pop-up lists None and your metadata presets, then **New…** (makes a preset and chooses it once saved)
and **Edit Presets…** (opens the editor on the chosen preset, or the first one). The editor, as in Lightroom, has the
preset's name, a Preset pop-up to switch presets (asking whether to save unsaved changes), and sections of fields:
Basic Info, Camera Info, IPTC Content, Copyright, Creator, Image and Status, the IPTC Extension fields, Three
Dimensional Projection and Video. Only checked fields are applied: a checked field left empty clears that field on the
photo, and an unchecked one is left as the photo has it. Typing in a field checks it; each section's checkbox and Check
All / Check None / Check Filled check several at once. Delete Preset… asks first. The same presets are in the Library's
Metadata panel (Preset pop-up), and presets made before keep working.

The footer's **Import Preset** saves Copy or Add, the right panel's choices (except keywords) and the destination under
a name (Save Current Settings as New Preset…), and applies them when chosen. Changing a choice afterwards shows the
preset as "(edited)" until it's updated (Update Preset); presets can be renamed and deleted, are shared by every
catalog, and each catalog remembers the one last chosen.

**Import N Photos** locks the window (only Cancel works) and shows the progress in its footer. The catalog window
switches to **Previous Import** (in the sidebar's Catalog section: the photos from the latest import) so the photos
appear as they come in. With no failures the window closes and a pill over the photos says what happened ("Imported 34
photos · 6 already in the catalog"); otherwise the window lists the failures until Done. Cancel (or closing the window,
after confirming) stops the import, keeping what's in so far.

## Slideshow

Window ▸ Impromptu Slideshow (`⌘Return`, as in Lightroom) plays the selected photos, or every photo in the grid from the
selected one on when one or none is selected, full screen on black. Each photo shows for 4 seconds and fades into the
next over 1 second; the slideshow repeats until you stop it. `Esc` or `⌘Return` stops it, `Space` pauses, and `←` /
`→` step. The next photo is rendered while the current one shows, so each fade starts from a sharp photo.

With a second display, Window ▸ Secondary Display ▸ Slideshow (`⌥⇧⌘Return`, also in the toolbar's display menu)
plays the slideshow on the secondary display while the main window stays in front for you to keep working. Choose it
again (it's then **Stop Slideshow**) to stop.

## Contact sheets

Window ▸ Contact Sheet (`⌃⌥⌘C`) opens a window of the selected photos when several are selected, otherwise every photo
in the grid (the folder, collection or other source with its filters), in grid order. Videos are left out. The photos
are fixed when the window opens, and you can open several contact sheets at once.

The middle of the window shows the pages as they'll print, with the photos' Develop edits; the sidebar on the right
sets them up, and the pages follow as you change it:

- **Headline** and **Description**, at the top of every page (they start empty for each sheet).
- **Text Color** and **Background Color**: black on white unless you choose others.
- **Page Size** (US Letter, A4, Tabloid or A3; Letter or A4 to begin with, by region), **Orientation** and **Page
  Numbers** ("2 of 3" at the bottom of each page).
- **Image Size**: larger photos mean fewer across the page. It moves in whole columns, and shows how many fit
  ("4 × 5 per page · 3 pages").
- **Image Border** (white), **Shadow**, and **Image Caption**: one line under every photo with the field you choose
  (Filename, Title, Caption, Capture Date, Capture Date & Time, Camera, Lens, Exposure, Rating, Creator or Copyright).

The choices other than the headline and description are remembered for the next sheet. **Generate…** asks where to save
the PDF and writes it in the background, rendering each photo at 300 pixels per inch of its cell (from its Smart
Preview when the original is missing; a gray placeholder with its name when neither can be read). The text stays text,
so the PDF can be searched. Cancel stops it without leaving a file behind.

## Library views

The left end of the Library's bottom toolbar has the view buttons, as in Lightroom: **Grid** (`G`), **Loupe** (`E`,
the selected photo enlarged), **Compare** (`C`) and **Survey** (`N`). The button for the view on show is highlighted;
Loupe and Survey need a selected photo and Compare needs two (or one with a photo after it). Compare's own bar starts
with the same buttons. The toolbar's sort order and thumbnail size are on the right.

## Develop Settings (Library)

Control-click photos in the grid for **Develop Settings ▸**, below Add to Collection (as in Lightroom):

- **Reset** clears all Develop settings of the selected photos (the same as `⇧⌘R`).
- **Copy Settings…** lists every Develop setting with a checkbox, grouped as in the Adjust panel (with **Check All** and
  **Check None**); the checked ones are copied. Everything but red eye, spot removal, masking and the crop is checked to
  start with.
- **Paste Settings** applies what was copied (or a preset copied in Develop) to the selected photos; it's available only
  when something has been copied.
- **Sync Settings…** (two or more photos selected) shows the same list and copies the checked settings from the photo
  the menu was opened on to the other selected photos.
- **Delete All Empty Masks** removes masks with nothing left in them.
- **Auto White Balance** sets each photo's white balance so the photo averages to gray (as Develop's Auto does).
- **Auto Settings** sets Exposure, Shadows, Whites, Blacks, Vibrance and Saturation for a quick, well-exposed start.
- **Convert to Black & White** applies the Black & White section's Auto.

Each is one undoable step (`⌘Z`) and is recorded in each photo's History.

## Library Filter

The Library Filter bar above the grid works like Lightroom's. Its header chooses the modes: **Text**, **Attribute**,
**Metadata** or **None**. Click a mode to show just it (click it again to turn it off), or Shift-click to add or
remove it; the active modes' rows all apply, so a photo must match every one. Each row's × clears that mode.

- **Text** searches the field chosen in its first menu (**Any Searchable Field**: file name, copy name, title,
  caption, creator, copyright, camera, lens, label text and keywords with their synonyms; or just **Filename**,
  **Copy Name**, **Title**, **Caption**, **Keywords**, **Camera & Lens** or **Creator & Copyright**) by the rule in
  its second: **Contains** (any of the words), **Contains All** (every word, part of a word counts; the default),
  **Contains Words** (every word, as a whole word), **Doesn't Contain** (none of the words), **Starts With** or
  **Ends With** (each word starts or ends a word). As in Lightroom, `!word` leaves out photos with the word, `+word`
  matches the start of a word and `word+` the end, whatever the rule. It searches as you type; `Esc` clears it and
  returns to the grid.
- **Attribute** has Lightroom's groups: **Flag** (Picked, Unflagged, Rejected), **Edit** (edited photos, which have
  Develop settings, or unedited ones), **Rating** (≥, = or ≤ a number of stars), **Color** (the five labels, another
  label such as a custom Lightroom one, or no label), **Kind** (originals, virtual copies, videos) and **Stack**
  (photos in a stack or not; a collapsed stack still shows only its top photo). A photo matches a group if it matches
  any of the group's choices that are on, and must match every group that has some.
- **Metadata** shows columns of metadata, Date, Camera, Lens and Label to start, each listing the values the photos
  have with how many have each. Click a value to show its photos, `⌘`-click to add more, or **All** to clear the
  column; each column lists only what the columns to its left leave, and the photos must match every column. The
  Date column opens into months and days. A column's header changes what it shows: Date, File Type, Keyword, Label,
  Flag, Rating, Camera, Lens, Focal Length, Shutter Speed, Aperture, ISO Speed, GPS Data, Treatment (color or black &
  white), Aspect Ratio, Creator, Copyright or Folder. It also adds a column (up to eight) or removes one. Drag the
  bottom edge to make the columns taller. The keyword list's arrow shows a keyword's photos (and those below it) by
  choosing it in a Keyword column.

The menu at the header's right shows the preset the filter matches (or Custom Filter) and applies one: Lightroom's
**Filters Off**, **Default Columns**, **Exposure Info** (Focal Length, Shutter Speed, Aperture and ISO columns),
**Flagged** and **Rated**, then your own. **Save Current Settings as New Preset…** saves the modes and their settings
under a name, for every catalog; while the filter matches one of yours, the menu also updates, renames or deletes it.
Applying a preset turns on its modes with its settings; the modes it leaves off keep theirs.

Turning a mode off (or choosing None) stops it filtering but keeps what it was set to, so turning it back on brings it
back. The filter stays as you move between folders and collections, and the bar, its modes and their criteria are
saved with the catalog. `\` hides the bar without clearing it; while it leaves photos out the filmstrip says so
("42 of 310 photos") with a filter icon that shows the bar again. `⌘F` shows the bar's Text mode and puts the cursor
in its field.

## Map

The Map module (View ▸ Map, `⌘3`, or Map in the toolbar) shows the photos the grid shows that have a location, as
pins on Apple Maps. It follows the source in the sidebar and the Library Filter bar, which it shows too.

- Nearby photos cluster into one pin with their count; zoom in to split them.
- Click a pin or cluster to select its photos in the filmstrip; selecting photos in the filmstrip highlights their
  pins, and moves the map to them when none is in view. Hover over a pin to see its photo.
- Double-click a pin to open the photo enlarged in the Library; double-click a cluster or the map to zoom in.
- The bar along the bottom chooses Standard, Satellite or Hybrid and zooms with a slider (pinch, scroll and the
  map's own buttons work too).
- The map opens fitted to the source's photos, and goes back to where you left it when you return to a source.
- The right sidebar is the Library's, so keywords, metadata and the GPS field work here too. Ratings, flags and
  labels apply to every selected photo.
- Locations come from the catalog (see the Metadata panel's GPS field), so the map works with originals offline;
  only the map itself needs an internet connection.

## Filmstrip

The filmstrip along the bottom of the window shows the photos in the current folder (with the current filters), in
both Library and Develop. Its selection stays in sync with the grid. The header shows the folder, photo count,
selection and the selected photo's path, with flag filters (Picked, Unflagged, Rejected) and the star filter on the
right. They're the Library Filter's Attribute criteria: changing them here turns its Attribute mode on.

## Dragging photos out

Drag photos from the grid or filmstrip to the Desktop, a Finder window or another app (Mail, Messages, a browser) to
copy them there. Each arrives as a full-size sRGB JPEG of the photo as it looks in PixelLoupe (edits, rotation and crop
applied, metadata kept), named after the original. Every selected photo is dragged.

## Compare

Press `C` (View ▸ Compare) with two photos selected to see them side by side: the first is the **Select** (left),
the second the **Candidate** (right). With one photo selected, the candidate is the next photo. Compare is a Library
view, as in Lightroom: pressing `C` in Develop switches to Library.

- Click a photo to make it active; ratings and flags apply to the active photo.
- The bar below has the lock, zoom slider, **Sync**, swap, previous/next candidate and **Done**. While locked (the
  default), zooming and dragging to pan apply to both photos; unlocked, only to the active one. **Sync** zooms and
  positions the Candidate like the Select photo.

## Survey

Press `N` (View ▸ Survey) to see every selected photo side by side, as large as they fit, to pick the best one (as in
Lightroom). Survey is a Library view: pressing `N` in Develop switches to Library.

- The active photo is outlined; ratings, flags and labels apply to it, and the right sidebar shows it. Click a photo
  or press `←` / `→` to make another one active.
- Point at a photo and click its close button to drop it from the survey (it's deselected). Selecting photos in the
  filmstrip changes what's surveyed.
- `⇧N` (Window ▸ Secondary Display ▸ Survey) shows a survey of the selection in the secondary window.

## Catalog

The Catalog section of the left sidebar (below the Navigator) has, as in Lightroom:

- **All Photographs:** every photo in the catalog.
- **Previous Import:** the photos of the most recent import, with their count. One run of the import window is one
  import, and so are the new photos Synchronize Folder adds; photos made in PixelLoupe (Photo Merge results, Edit In
  copies) aren't imports, and a virtual copy goes with the photo it copies. While it's showing, a new import takes its
  place as the photos come in; if every photo of the last import is removed, it shows the one before. It's dimmed
  until something is imported, which includes catalogs made before PixelLoupe kept track of imports (until their next
  import). A catalog imported from Lightroom Classic starts with Lightroom's own previous import.

The grid's source (a Catalog item, folder or collection) is restored when the catalog is opened again.

## Folders

The Folders section of the left sidebar mirrors the folders photos are in. Control-click a folder for Lightroom's folder
menu:

- **Create Folder Inside "Folder"…** makes a subfolder on disk and in the catalog.
- **Create Collection Set "Folder"** makes a collection set mirroring the folder: its own photos in a collection of the
  same name, each subfolder as a collection (or a set, if it has subfolders of its own).
- **Create Collection "Folder"** makes a collection of the folder's photos, subfolders included.
- **Add to Favorites** marks the folder with a yellow star; **Add Color Label to Folder** colors its icon with one of
  the photo label colors.
- **Rename…** renames the folder on disk and in the catalog. **Remove…** takes the folder and its photos out of the
  catalog; the files stay on disk. Both can be undone (`⌘Z`).
- **Hide This Parent** (a top-level folder with subfolders and no photos of its own) makes its subfolders top-level;
  **Show Parent Folder** adds a top-level folder's parent back.
- **Synchronize Folder…** compares the folder with the disk: imports new photos (in place, or through the import
  window), removes photos whose files are gone (**Show Missing Photos** selects them instead), and re-reads files that
  changed for their camera, lens, size, shooting details and keywords.
- **Update Folder Location…** (and **Find Missing Folder…** for a folder that can't be found) points the folder at
  where it is now.
- **Import to this Folder…** opens the import window copying into the folder.
- **Export this Folder as a Catalog…** makes a new catalog of the folder's photos with their edits, history, keywords,
  stacks, virtual copies and collections; optionally copying the files next to it (**Export negative files**) and the
  thumbnails (**Include available previews**).
- **Show in Finder** and **Get Info** (which asks the Finder to open its Get Info window; macOS asks once whether
  PixelLoupe may control the Finder).

## Collections

The Collections section of the left sidebar (below the folders) holds, as in Lightroom:

- **Collections:** photos you add by hand. Drag photos from the grid or filmstrip onto one, use right-click ▸ Add to
  Collection, or make it the **target collection** and press `B` (the target is marked with `+`).
- **Smart collections:** photos matching rules, kept up to date. Rules cover rating, pick flag, keywords, camera, lens,
  capture/import/edit date (including "is in the last N days/weeks/months/years"), file name, file type, folder and
  whether the photo has adjustments, matched all or any.
- **Collection sets:** folders of collections. Selecting a set shows everything in its collections.

Create them from Library ▸ New Collection (`⌘N`) / New Smart Collection / New Collection Set, the **⊕** menu on the
Collections header (which also sorts by name or kind and shows or hides **Filter Collections**), or a set's right-click
menu. The chevron beside ⊕ collapses the section to its heading; it stays that way until it's opened again. Right-click a collection to rename, delete, edit its rules or make it the target. New catalogs (and existing ones,
once) get Lightroom's starter smart collections: Five Stars, Past Month, Recently Modified and Without Keywords. Every
change is undoable.

## Right sidebar (Library)

The `sidebar.right` toolbar button shows or hides the Library's right sidebar, for the selected photos:

- **Histogram:** as in Develop, but not editable. Computed from the thumbnail, so it reflects edits.
- **Keywords:** click in the field or press `⌘K` (Photo ▸ Add Keywords), then type keywords separated by commas (or
  press Return). Each becomes a pill; its ✕ removes the keyword.
  With several photos selected, keywords go to all of them, and ones on only some are dimmed and marked `*`.
- **Metadata:** the pop-up chooses one of Lightroom's metadata sets (Default, All Plug-in Metadata, DNG, EXIF,
  EXIF and IPTC, IPTC, IPTC Extension, Large Caption, Location, Minimal, Quick Describe, Three Dimensional
  Projection, Video). Values come from the photo's EXIF, TIFF, GPS, IPTC, DNG and XMP metadata.
  - Fields such as Title, Caption, Copyright and the IPTC fields are editable. Edits are saved in the catalog only
    (the original files are never changed) and are undoable; Metadata Status shows "Has been changed".
  - **Target Photo / Selected Photos:** edit just the first selected photo, or all of them. Values that differ
    between the selected photos show ‹mixed›.
  - **GPS** sets the photo's location in the catalog: type the shown form (`37°46′29.7″ N 122°25′9.9″ W`) or
    decimal degrees (`37.7749, -122.4194`); clear it to remove the location even if the camera recorded one. Smart
    collections' Has GPS and the Library Filter's GPS Data follow it. Catalogs from before this read their photos'
    locations in the background after opening.
  - **Preset:** save the target photo's filled-in fields as a preset and apply it to other photos.
  - The arrow buttons show a photo's folder in the Library, reveal the file in the Finder, or show its GPS location
    in Maps.

- **Location:** a small map of the photos' location (or "Multiple locations"), and a field that finds an address or
  place as you type (↑ ↓ and Return pick one) or takes "lat, lon", which works offline. Drag the pin to fine-tune.
  **Apply** gives the place to the photos that have no location; **Replace** gives it to all of them, asking first
  when that replaces a location the camera recorded; **Remove** takes the location away, even the camera's. They act
  on every selected photo (not just the target photo, whatever Metadata's Target Photo / Selected Photos says), are
  saved in the catalog only (the original files keep theirs, and exports use the catalog's) and are undoable.

## Curves (Develop)

The Curves section has **Parametric**, **Point** and **R / G / B** modes. In a point mode, click the graph to add a point
(up to 16), drag a point to move it, drag it off the graph or double-click it to delete it, and double-click empty space to
reset the curve. Parametric mode shows the four regions (Shadows, Darks, Lights, Highlights) as sliders and lets you drag
the dividers between them. The parametric curve is applied before the point curve; both are baked into the color table.

## Color (Develop)

**Color Mixer** has Hue / Saturation / Luminance tabs (a slider per color) and an All tab (pick a color, see its three).
**Color Grading** has Shadows, Midtones, Highlights and Global wheels with Blending and Balance. With **Black & White** on,
its Mix sliders (one per color) take the Color Mixer's place, as in Lightroom. Grain is in **Effects**, so color photos can
have it.

## Detail and effects (Develop)

**Sharpen** has Amount, Radius, Detail and Masking; hold Option while dragging Masking to see the mask in the preview.
It works the same on RAW and other files (an active sharpen replaces the RAW engine's default). **Noise Reduction** has
Amount, Color and Detail (Detail applies to non-RAW files). **Post-Crop Vignette** has Amount, Midpoint, Roundness,
Feather and Highlights, and Highlight Priority, Color Priority and Paint Overlay styles. **Effects** has Grain with
Amount, Size and Roughness; each photo has its own grain pattern, and the size is in full-size pixels, so it looks the same
fitted or at 100%.

## History and snapshots (Develop)

The **History** tool lists a photo's edits, newest first, and **Snapshots** above it. Every edit in Develop adds a step (the first
adds an "Original" step); click a step to take the photo back to it, and the next edit drops the steps after it, as in
Lightroom. ⌘N in Develop saves a snapshot (File ▸ New Snapshot; it is New Collection elsewhere); click a snapshot to apply
it, double-click its name to rename it, and Update or Delete it with the buttons. The panel's right-click menu has Clear
History. ⌘Z still undoes the last edit, and takes its history step with it. A photo keeps its latest 500 steps, each stored as
a few hundred bytes of compressed JSON with only the sections that differ from the defaults. The Lightroom import sheet has
**Import develop history and snapshots** (off by default): steps and snapshots come across with their dates and names, as
compressed Lightroom settings that are converted the first time the photo's History is shown.

## Spot removal and red eye (Develop)

The **Spot Removal** tool (**Q**) removes blemishes: pick Heal or Clone, then click the photo. A circle marks the spot and a
dashed one its source (chosen beside it); drag either, and use the sliders for Size, Feather and Opacity. To resize a spot,
drag one of the four handles on the circle under the pointer or the selected one, or scroll. A new spot takes the size of
the last one you resized, as it looked on screen, so zoomed in it covers less of the photo. Heal
keeps the source's texture and takes the colors and brightness around the spot; Clone copies it as it is. Choose Red Eye and click
an eye: PixelLoupe finds the red pupil near the click, takes the red out and darkens it. Delete, or the ⓧ button on its row in
the list, removes a spot. Spots
are drawn on the photo as decoded, before the other edits, and stored as shapes. A Lightroom import brings in spots (heal and
clone) and red eyes; generative or AI removals can't be imported and are reported.

## Masking (Develop)

The **Masking** tool (⇧W, or its button in the Develop sidebar) adjusts part of a photo. **M** adds a linear gradient, **⇧M** a
radial one, and **O** shows the selected mask in red. On the photo, drag a linear gradient's lines (or its middle to move it),
or a radial gradient's handles (edge, feather ring, center, and the outer handle to turn it). Each mask has Amount, Exposure,
Contrast, Highlights, Shadows, Whites, Blacks, Temp, Tint, Saturation, Clarity, Texture and Dehaze sliders and an Invert
checkbox, and the red ⊗ button at the end of its row in the mask list deletes it; all of it is undoable. Masks are stored as shapes, not bitmaps, in the photo's coordinates before
cropping, so they stay on the subject if the crop changes. Brush, range and AI (subject, sky, people) masks aren't
available yet; a Lightroom import brings in linear and radial gradients (the old graduated and radial filters and the newer
masks) and reports the rest.

## Crop import

A Lightroom crop and its straightening angle import as a PixelLoupe crop (`LightroomCropConverter`): the rectangle's y axis
is flipped, the angle's sign is flipped, and the rectangle's center is carried around the photo's center by the angle. A
crop that matches the photo's proportions imports as Original, and one that matches a menu ratio (within 0.5%) as that
ratio; "Constrain Aspect Ratio" decides whether the aspect is locked. The direction and frame conventions follow the
Jira description and haven't been checked against Lightroom exports.

## Transform (Develop)

The Adjust panel's **Transform** section corrects perspective: Vertical, Horizontal, Rotate, Aspect, Scale and X/Y Offset
sliders, **Constrain Crop** (zoom in until no empty corner shows) and Upright. Upright ▸ **Level** measures the tilt (horizon,
else straight edges) and sets Rotate; Auto, Vertical, Full and Guided need analysis PixelLoupe doesn't have yet. The warp is
one projective resample on the GPU, applied after orientation and before the crop. A Lightroom import brings the manual
sliders across; Upright's mode and stored matrix are recorded but not applied yet (their format hasn't been verified), and
the photo is reported.

## Lens profile import

A Lightroom photo that used an Adobe lens profile gets the LensFun profile for the same lens (matched by the profile's lens
name, then the photo's lens, and the camera's mount). With no match the camera's own correction is used where it has one and
the photo is reported.

## Presets (Develop)

The Presets tool (second icon in Develop's right panel) lists Lightroom presets by group, searchable by name.
Double-click a preset (or select it and click **Apply**) to apply it to the photo: only the settings the preset holds
change, as in Lightroom, and it's one undoable step in the photo's History, named after the preset. **Copy** puts the
preset on the settings clipboard; **Photo ▸ Paste Settings** (`⇧⌘V`) then applies it to every selected photo, in
Develop or in the Library grid. **Photo ▸ Copy Settings** (`⇧⌘C`) copies a photo's own settings instead (pasting them
keeps each photo's crop, rotation, spots, red eye and masks).

Presets are Lightroom / Camera Raw `.xmp` files. The options menu (…) at the top of the panel imports presets (files or
folders) into `~/Library/Application Support/Pixegen/PixelLoupe/Settings`, one folder per group; **Import Lightroom's
Presets** brings in the ones Lightroom installed (`/Library/Application Support/Adobe/CameraRaw/Settings`, and older `.lrtemplate` ones). Profiles
go to their own library (below). After applying a preset that supports it, an **Amount** slider (0–200%) under the
list scales it, from the photo as it was before the preset (0%) to the preset (100%) and beyond: numbers move
between the two, on/off settings and differently shaped curves switch at 50%. Each drag is one undoable step in History
("Preset: Punch 50%"); another edit, or another photo, ends the slider. ISO-adaptive presets (Lightroom's "+ NR" defaults) set their noise
reduction for the photo's ISO, interpolated between the ISOs they list; baseline presets ("Adobe Default", "Camera
Settings", and the defaults built on them) start from PixelLoupe's defaults, keeping the photo's crop, rotation,
spots, red eye and masks.

To make your own preset, click **+** at the top of the panel (Create Preset…): name it, pick or type a group, and
check the settings it holds (White Balance, Basic Tone, Presence, Tone Curve, Color Mixer, Color Grading, B&W, Detail,
Effects, Lens Corrections, Transform, Calibration, Profile). It's saved as a Lightroom-compatible `.xmp` in the presets
library, so Lightroom and Camera Raw can use it too; PixelLoupe-only settings aren't written. Right-click a preset for
Apply, Copy, **Update with Current Settings** (the same settings it held, from the photo, keeping its UUID),
**Rename…**, Show in Finder and **Delete** (to the Trash); right-click a group to rename it.

Hovering over a preset previews it on the photo and in the Navigator, without applying it; moving off the list puts
the photo back. As in Lightroom, the list shows only the presets that suit the photo: ones restricted to another
camera (`CameraModelRestriction`), made only for monochrome cameras or only for color ones (`SupportsColor`,
`SupportsMonochrome`), or only for HDR editing are hidden. Presets that only partly apply (their profile isn't
imported, or isn't for this camera) are dimmed, with the reason in their tooltip; **Show Partially Compatible
Presets** in the panel's options menu (…) hides them. Older Lightroom presets (`.lrtemplate`, Lightroom 7.2 and
earlier) import too and are saved as `.xmp`; their spot removal and local corrections aren't carried over.

## Adobe profiles (Develop)

Importing presets also imports Adobe's profiles (`.xmp` files of looks: Adobe Raw, B&W, Modern, Vintage, Artistic
and the camera-matching profiles) into `~/Library/Application Support/Pixegen/PixelLoupe/Profiles`. The Profile pop-up
then lists them by group after PixelLoupe's own looks (camera-matching ones for the photo's camera only). Moving through
the menu previews the highlighted profile on the photo and in the Navigator; closing it without choosing puts the
photo back. They render from their own tables: the look table (hue, saturation and value changes over ProPhoto RGB) and the RGB table
(a 3-D lookup in its own color space, usually Adobe RGB), each baked into a color cube at the profile's Amount, under
the curves, color grading and black and white. Settings that come inside a profile (Adobe Vivid's clarity and curve,
a B&W profile's contrast) render with it without moving the sliders. Presets and imported Lightroom catalogs that
name a profile use it when it's been imported, by its UUID or name; a B&W profile makes the photo black and white.
Adobe's default (Adobe Color / Standard) stays PixelLoupe's own rendering, and PixelLoupe's RAW rendering itself isn't
Adobe's, so results are close to Lightroom's rather than identical.

## Profiles and calibration (Develop)

The **Profile** section has PixelLoupe's own looks (Default, Neutral, Vivid, Landscape, Portrait, Monochrome) and an Amount
(0–200). They are built into the color table and run first; they approximate Adobe's profiles, which can't be reproduced.
**Calibration** rotates and strengthens the red, green and blue primaries and tints the shadows. A Lightroom import maps
Vivid, Landscape, Portrait, Monochrome and Neutral (Adobe or Camera) to the matching look and reports each photo; Adobe
Color and Standard import as Default and are counted once in the report; Embedded is nothing; any other profile is listed
by name.

## White balance (Develop)

White Balance is the first section of the Adjust panel after Profile, as at the top of Lightroom's Basic panel. It has the
White Balance Selector (the eyedropper, also **W**), a **WB:** pop-up, and **Temp** (2,000–50,000 K, on a track that gives
the low end more room) and **Tint** (−150…+150) sliders drawn blue to yellow and green to magenta.

- The pop-up lists As Shot, Auto, Daylight, Cloudy, Shade, Tungsten, Fluorescent, Flash and Custom for RAW files, and only
  As Shot, Auto and Custom for other files. Moving a slider makes it Custom. As with the Profile menu, the pointer (or
  arrow keys) moving through the open pop-up previews each white balance on the photo and in the Navigator; closing it
  without choosing puts the photo back.
- The selector shows a floating loupe beside the pointer: **Pick a Neutral Target** above a magnified 5 × 5 grid of the
  photo, and the grid's average (R, G, B in percent) below. Click something that should be neutral and the temperature
  and tint are set to make it so.
- Auto assumes the photo averages to gray. Each change is one undo step. Higher temperature is warmer, for RAW and other
  files alike. Exposure runs −5…+5 stops.

## Histogram (Develop)

The top of Develop's right sidebar shows the photo's red, green and blue histogram as edited (gray where all three
overlap), with the ISO, focal length, aperture and shutter speed underneath.

- **Drag to adjust**, as in Lightroom: the histogram is split into five zones, from left to right Black Point,
  Shadows, Exposure, Highlights and White Point (Levels ▸ Input White). Hover to see the zone and its value; drag right
  to brighten, left to darken. Each drag is one undoable edit.
- **Clipping:** the triangles in the top corners light up when shadows (left) or highlights (right) are clipped, in
  the clipped channels' color (white for all three). Hover to preview the clipped areas on the photo (blue for
  shadows, red for highlights), click to keep them shown, or press `J` for both.

## Lens Corrections (Develop)

The camera icon at the top of Develop's right sidebar shows Lens Corrections, with Lightroom's two tabs.

- **Profile:**
  - **Remove Chromatic Aberration** uses the lens profile's data, or measures the photo's lateral color fringing.
  - **Enable Profile Corrections** applies the camera's built-in lens profile when the RAW file carries one (shown as
    "Built-in Lens Profile applied"). Otherwise it applies the matching [LensFun](https://github.com/lensfun/lensfun)
    profile for the photo's camera, lens, focal length and aperture.
  - **Setup:** Auto picks the profile; choosing a Make, Model or Profile switches to Custom.
  - **Amount:** Distortion and Vignetting scale the profile's corrections (0–200).
- **Manual:**
  - **Distortion:** Amount corrects barrel (positive) or pincushion (negative) distortion. **Constrain Crop** enlarges
    the photo so no empty edges show.
  - **Defringe:** removes purple and green fringes along high-contrast edges. Set the Amount, and the hue range with the
    two-thumb slider, or click the eyedropper and then a fringe on the photo.
  - **Vignetting:** Amount brightens (positive) or darkens the corners; Midpoint sets how far in it reaches.

Corrections are part of the non-destructive edit and show everywhere the photo does. Each photo keeps its resolved
profile, so thumbnails never need the lens database.

## Crop & Straighten (Develop)

The icons at the top of Develop's right sidebar switch between the Adjust tools and Crop & Straighten (`R`).

- **Aspect:** As Shot, Original, Custom, print sizes (1 x 1, 4 x 5 / 8 x 10, 8.5 x 11, 5 x 7, 2 x 3 / 4 x 6), screen
  sizes (4 x 3, 16 x 9, 16 x 10) or Enter Custom…. With the lock closed, resizing keeps the ratio; `X` swaps
  landscape/portrait.
- **Angle:** −45° to 45°. **Auto** levels the photo by its long straight lines (buildings, rooflines, door frames,
  horizons), falling back to Vision's horizon detection, and crops in so there are no empty corners. Photos with
  nothing straight to go by (trees, rock) beep and say so. The ruler button is Lightroom's Straighten tool: drag
  along something that should be level. Dragging outside the crop also rotates.
- **Photo menu:** Rotate Left / Right (`⌘[` / `⌘]`), Flip Horizontal / Vertical, Reset to Camera Orientation and
  Restore Orientation from Metadata. The crop turns with the photo.
- **Constrain to Image** keeps the crop inside the photo (no empty corners). **Tool Overlay** shows the
  rule-of-thirds grid while dragging (Auto), always or never.
- Drag the corners or edges to resize and inside to move. `Return`, `R`, **Close** or switching tools applies the crop
  (one undoable edit); `Esc` cancels. Like every edit it's non-destructive, and it shows everywhere: grid,
  filmstrip, enlarged view, Compare and the loupe.

## Loupe (Develop)

Press `` ` `` (or click the loupe button in the toolbar) to show or hide the loupe. Hold `` ` `` and click the photo
to place it on a spot.

- Drag the ring or tab to move the loupe while it magnifies.
- Drag from inside the lens to reposition it: the photo shows unmagnified, with an outline of the area that will be
  magnified when you release.
- Drag the grip at the lower right to resize.
- Click the zoom value for 50%–1600% (100% is the original's actual pixels), Focus on Loupe/Cursor, Pixel Grid,
  Color Value, Use Centered Loupe and Hide Loupe.

## Before/After (Develop)

View ▸ Before/After compares the photo with how it was before its edits, using Lightroom's keys. The before keeps the
photo's framing (orientation, crop and straightening, and the Transform sliders) so the two line up; everything else
is back at its defaults.

- **Left/Right** (`Y`) and **Top/Bottom** (`⌥Y`): the before and the edited photo side by side, each as large as fits.
  Zooming (`Z`, a click, the Navigator) zooms both alike, and dragging pans both.
- **Before Only** (`\`): the before in place of the edited photo; `\` again shows it edited.
- **Split Screen** (`⇧Y`): one photo with a line down the middle, the before left of it and the edited photo right of it.

Press the same key again (or choose the checked item) to go back to the edited photo. The view stays as you move from
photo to photo. Crop & Straighten, Masking and Spot Removal show the photo their own way: opening one ends
Before/After, and choosing a Before/After view closes it. The histogram always shows the edited photo.

## Export

File ▸ Export… (`⇧⌘E`) opens the Export dialog for the selected photos, laid out like Lightroom's: presets on the
left (PixelLoupe's For Email, For Website and Full Sized JPEGs, then your own, with Add and Remove), settings on the
right:

- **Export Location:** a specific folder, the original's folder, or one chosen at export; an optional subfolder; and
  what to do with existing files (ask, choose a new name, overwrite or skip).
- **File Naming:** Filename, Filename - Sequence, Filename-Edit, Custom Name (with a sequence, or "x of y"), Date - Filename; lower- or
  uppercase extensions.
- **File Settings:** JPEG (quality, or a file size limit), HEIC, TIFF (8/16-bit, LZW or ZIP), PNG (8/16-bit), PSD, or
  the untouched Original; sRGB, Display P3, Adobe RGB (1998) or ProPhoto RGB.
- **Image Sizing:** width & height, dimensions, long or short edge, megapixels or percentage, in pixels, inches or
  cm; resolution; Don't Enlarge.
- **Output Sharpening** for screen, matte or glossy paper; **Metadata** (from copyright only to all, removing person
  or location info), with Title, Caption, keywords, the GPS location and other metadata typed into PixelLoupe (a
  location removed in PixelLoupe leaves the exported file with none); **Watermarking** with your
  watermark presets; and **Post-Processing** (show in Finder or open in another app).

Video is shown as in Lightroom but disabled: PixelLoupe doesn't import video yet. Export with Previous (`⌥⇧⌘E`) repeats
the last export's settings and File ▸ Export with Preset uses a preset directly. Exports run in the background, a few
photos at a time, with progress and Cancel in the Library's bottom bar. Presets are shared by every catalog, in
`~/Library/Application Support/PixelLoupe/Export Presets`.

## Photo Merge: HDR

Photo ▸ Photo Merge ▸ HDR… (`⌃H`, also in the grid's right-click menu) merges two or more bracketed RAW photos of the
same scene into one high-dynamic-range photo, as Lightroom does. The HDR Merge Preview sheet shows the result on the
left, updating as the options on the right change. Click the photo to zoom to 100% (the part shown is merged at full
resolution), drag to look around, and click again to fit it:

- **Auto Align** lines the photos up (for brackets shot without a tripod). It corrects shifts, not rotation.
- **Auto Settings** tone maps the merge so the highlights and the shadows both show, matched to Lightroom's HDR
  merges: the scene's brightness is split into an edge-aware base layer and local detail, the base layer's range is
  compressed (more for scenes with more range) with the midtones at middle gray and the highlights rolling off, and
  the detail is kept. Off, the merge is the plain scene radiance. Either way the merged photo starts at the default
  Develop settings with the camera's white balance (As Shot), as in Lightroom.
- **Deghost Amount** (None, Low, Medium, High) finds things that moved between the photos (people, leaves, water) and
  uses a single photo there: the middle exposure where it's well exposed, otherwise the nearest one that is. Higher
  amounts catch smaller differences. **Show Deghost Overlay** outlines those areas in red.
- **Create Stack** stacks the merged photo on top of its sources, darkest first, collapsed (or adds it to the top of
  the stack the sources already share).

The merge runs on the GPU in Core Image kernels (`PixelLoupe/Merge/HDRMergeKernels.ci.metal`); the preview is the
same merge at the sheet's size, so it shows what Merge makes. Merge runs in the background with progress and Cancel in
the Library's bottom bar, and selects the result when it's done. The merged photo is a Linear DNG (16-bit floating point) saved beside the earliest photo as
`<name>-HDR.dng` (`-HDR-2`, `-HDR-3`… when that name is taken), so it develops like any RAW file with highlights
several stops above white to recover (stored in 256×256 tiles, as cameras do). It takes the middle exposure's white balance, capture date, camera and shooting
details, and every source's keywords; its rating, flag and label start empty. Only RAW photos from one camera, all
the same size, can be merged.

Photo ▸ Photo Merge ▸ HDR with Previous Settings (`⌃⇧H`, or hold Shift in the menu) merges straight away with the last
options used, without the sheet, in the background as Merge does. Panorama with Previous Settings (`⌃⇧M`) works the same
way. When the photos can't be merged (a JPEG among them, or photos from different cameras), an alert says why.

## Photo Merge: Panorama

Photo ▸ Photo Merge ▸ Panorama… (`⌃M`, also in the grid's right-click menu) merges two or more overlapping RAW photos
into one panorama, as Lightroom does. The Panorama Merge Preview sheet shows the result on the left, updating as the
options on the right change. Click the panorama to zoom to 100% (the part shown is merged at full resolution), drag to
look around, and click again to fit it. The sheet says how many of the photos merged: photos that don't overlap any of
the others are left out ("10 of 12 photos merged").

- **Projection:** **Spherical** maps the photos to the inside of a sphere, for very wide or multi-row panoramas.
  **Cylindrical** maps them to the inside of a cylinder, for wide panoramas, keeping verticals straight.
  **Perspective** maps them to a flat surface, keeping straight lines straight (architecture); it can't show photos
  spanning more than 150°, so it's unavailable for those.
- **Boundary Warp** (0–100) bends the panorama's ragged edge out toward its rectangle, keeping the shapes of what's in
  it as much as it can, so less is lost to cropping. At 100 the panorama fills (nearly) the whole rectangle.
- **Auto Crop** crops away the edges the photos don't reach, to the largest rectangle they cover entirely. It's a
  Develop crop on the whole panorama, so it can be widened again in Crop & Straighten.
- **Auto Settings** starts the panorama with Develop's Auto Settings (tone), measured inside that rectangle.
- **Create Stack** stacks the panorama on top of its sources, in the order they were taken, collapsed (or adds it to
  the top of the stack the sources already share).

Where the photos don't reach, the sheet shows a checkerboard and the merged photo is white (in Develop, thumbnails and
exports). When a photo has no lens profile to apply, the sheet shows Lightroom's notice: for the best results, apply the
lens's profile in Develop's Lens Corrections before merging. Photo ▸ Photo Merge ▸ Panorama with Previous Settings
(`⌃⇧M`, or hold Shift in the menu) merges straight away with the last options used, without the sheet; Perspective
becomes Spherical for photos it can't show.

Each photo is decoded linearly with the earliest photo's white balance, its lens profile applied (the camera's built-in
profile, its Lens Corrections profile in Develop, or the LensFun profile for its camera and lens), and scaled by its
exposure (shutter speed, aperture and ISO) to the photos' average, as Lightroom's merges render. Corners found in each
photo are matched between every pair, and the matches give each photo's rotation and the lens's focal length, refined
together and levelled so the horizon is straight and verticals stand up. Seams follow where neighboring photos look
most alike (a graph cut, so they go around things that moved, like water and leaves), brightness differences the
exposures don't explain are evened out, and the photos are blended across the seams band by band (a Laplacian
pyramid) on the GPU, in Core Image kernels (`PixelLoupe/Merge/PanoramaKernels.ci.metal`). The preview is the same
merge at the sheet's size. Merge runs in the background with progress and Cancel in the Library's bottom bar, and
selects the result when it's done. The panorama is a Linear DNG (16-bit floating point) at the photos' own resolution,
up to Lightroom's limits (65,000 pixels on a side, 512 megapixels), saved beside the earliest photo as `<name>-Pano.dng`
(`-Pano-2`, `-Pano-3`… when that name is taken). It takes the earliest photo's capture date, camera and shooting
details, and every source's keywords; its rating, flag and label start empty. Only RAW photos from one camera, all the
same size, can be merged. Lightroom's Fill Edges and HDR Panorama aren't available yet.

## Edit In (external editors)

Photo ▸ Edit In (also in the grid's right-click menu) sends the selected photos to another app, such as Photoshop,
Pixelmator Pro or Affinity Photo, and brings the result back, as Lightroom does:

- **Edit in (primary editor)** (`⌘E`) and **Edit in (additional editor)** (`⌥⌘E`) use the apps chosen in Settings ▸
  External Editing; the additional editor's saved presets are listed below them. **Open in Other Application…** picks
  the app (and file options) each time.
- **Raw photos and virtual copies** are always sent as a new file with their PixelLoupe adjustments applied. For other
  images (JPEG, TIFF, PSD, PNG, HEIC) a sheet asks what to edit: **a copy with PixelLoupe adjustments** (the default),
  **a copy** of the original file, or **the original** itself. It warns when the photo's adjustments would be left out.
- **Copies** are written beside the original, named `IMG_0002-Edit.tif` (Filename-Edit; `-2`, `-3`… when the name is
  taken), and join the catalog straight away with the original's rating, color label, keywords and metadata (not its
  flag) and default Develop settings (the edits are already in the pixels). With **Stack With Original** they go into a
  stack just above the original, and a photo edited from a collection is added to that collection. Adding them can't be
  undone, like an import: remove the photo instead. Copies are written in the background with progress in the bottom
  bar, then open in the editor together.
- **Bringing edits back:** while the catalog is open, PixelLoupe watches the folders of files it handed out (FSEvents),
  and whenever it becomes the active app or opens the catalog it looks for any photo whose file is newer than its
  thumbnail. Such a photo's size and dimensions are updated, its thumbnail is redrawn, and Develop and Compare load it
  again. Its Develop settings stay and still apply on top of the new pixels.

Settings ▸ External Editing has a section for each editor (Application with Choose… and Clear; File Format TIFF or PSD;
Color Space sRGB, Display P3, Adobe RGB or ProPhoto RGB; Bit Depth 8 or 16; Resolution; Compression None, LZW or ZIP for
TIFF), a Preset pop-up for the additional editor (Save Current Settings as New Preset…, Rename, Delete), Stack With
Original, and Edit Externally File Naming (Export's templates with Custom Text and Start Number, and an example).
The primary editor starts at 16-bit ProPhoto RGB TIFF with ZIP, the additional at 8-bit sRGB TIFF with LZW, as in
Lightroom. There is no HDR column: PixelLoupe edits in standard dynamic range. PSD copies are flattened, and PixelLoupe
reads PSD files' flattened composite, so layers added in the editor show as the composite.

## Watermarks

PixelLoupe ▸ Edit Watermarks… opens the Watermark Editor, laid out like Lightroom's. The preview starts at the selected
photo, and ◀ ▶ step through the photos in the grid (with several selected, through those; with no photos, a sample). Choose **Text** (font, style, alignment, color and a
shadow with opacity, offset, radius and angle) or **Graphic** (a PNG or JPEG), then set the opacity, size
(proportional to the photo's width, fit or fill), insets, anchor and rotation. Sizes are relative to the photo, so a
watermark looks the same at any export size.

Watermarks are saved as presets shared by every catalog, in `~/Library/Application Support/PixelLoupe/Watermarks`. The
preset pop-up offers Lightroom's Simple Copyright Watermark, your presets, and Save Current Settings as New Preset,
Update, Rename, Delete and Restore Default Presets; an edited preset shows "(edited)". Save asks for a name when the
watermark is new or edited. Export (RAW-14) applies a watermark preset.

## Keywords

Keywords form a tree, as in Lightroom (`Places > Ireland > Dublin`). In the Library's right sidebar, **Keywords** takes
typed names: `Places > Ireland > Dublin` (or with `|`) makes or reuses that path, a plain name uses the one keyword
with that name (a pop-up asks which when several share it), and a new name makes a top-level keyword. Pills show the
keyword's own name and the full path as a tooltip. **Keyword List** shows the tree with photo counts and a filter
field; its checkboxes add a keyword to, or remove it from, the selected photos, the arrow beside a count shows that
keyword's photos, and the context menu creates, renames, deletes and edits (synonyms and export options) keywords.
The keyword filter and the smart-collection rule "Keywords contains…" also match keywords below the one chosen, and
synonyms.

## People

A Lightroom import keeps the people you named: person keywords are marked as people, listed together under **People** at the top
of the Keyword List (they stay in the tree too), and each face region Lightroom found is kept with its photo (its rectangle, a
status of suggested, confirmed or ignored, and the person it was named with). PixelLoupe doesn't detect or cluster faces yet; the
regions are there for a People view to use later. A smart collection can use the rule **Person** (is, is not, contains…), which
matches person keywords only.

## Smart collections and custom order

Smart collections match on rating, pick, color label, keywords (and their parents and synonyms), dates, file type
(including Video), camera, lens, **ISO, focal length, aperture, shutter speed**, GPS, cropped, black & white, title,
caption, creator, copyright, any searchable text, and membership of another collection. "Match" can be *all*, *any* or
*none* of the rules, and rules can be grouped (groups come from Lightroom imports; the editor keeps them as they are).

In a collection, **Custom Order** in the Sort pop-up shows the photos in the collection's own order (Lightroom's order for
imported collections). Drag photos in the grid to reorder them; it is undoable.

## RAW+JPEG pairs, PSD and video

A RAW file and a JPEG with the same name in the same folder import as **one photo** (Lightroom's default): the RAW is
the photo, the JPEG is its sidecar. The Inspector's File Type shows `Raw + JPEG`, and removing the photo from disk
moves the JPEG to the Trash with it. **Settings ▸ Import ▸ Treat JPEG files next to RAW files as separate photos**
imports them as two photos instead. Photoshop (`.psd`) files import and show like any image. Video files (MOV, MP4, M4V…)
import as view-only items: they get a poster-frame thumbnail with a play badge and duration, the viewer plays them with
the standard controls, and Develop and Export leave them alone. A Lightroom import brings across the same kinds,
including a video's duration, trim points and poster frame.

## Importing a Lightroom Classic catalog

File ▸ Import Lightroom Catalog… (also a button in the Welcome window) turns a Lightroom Classic catalog (`.lrcat`,
Classic 13 or later) into a **new** PixelLoupe catalog. It is a one-time import: the Lightroom catalog is only read, and
photos stay where they are (a Referenced catalog), never copied or moved.

The open panel starts in `~/Pictures/Lightroom`. If Lightroom has the catalog open, PixelLoupe offers to import a
snapshot (a temporary copy of the catalog and its write-ahead log); Lightroom's own files are not changed. A summary
sheet lists what the catalog holds (photos and how many are missing on disk, folders, keywords, collections, virtual
copies, stacks, photos with edits or masks, file types PixelLoupe can't open) and asks for the new catalog's name and
location, which default to the Lightroom catalog's name next to it. Progress shows each step and Cancel deletes the
partly imported catalog.

When the import finishes, the report lists the totals and the photos whose settings were only partly imported, grouped
by reason, with a **Show Photos** button for each group. It is saved in the catalog package as `LightroomImport.json`
and reopens from Library ▸ Lightroom Import Report. The "Imported with Differences" smart collection (rule: *Imported
with Differences is true*) gathers those photos.

Develop settings are imported by `LightroomDevelopMapper`. So far:
**Exposure**; **White Balance** (a RAW file's temperature, tint and preset name; a JPEG's incremental temperature and
tint; Auto becomes As Shot and is reported); and the Basic sliders (Contrast, Highlights, Shadows, Whites, Blacks,
Texture, Clarity, Dehaze, Vibrance, Saturation); tone curves (point curves exactly, over 16 points simplified and
reported; parametric sliders and splits); and the color tools (HSL, color grading with split toning from older
catalogs, black & white with the gray mixer); and detail and effects (sharpening, noise reduction, post-crop
vignette, grain). Lightroom's default RAW sharpening and color noise reduction are not treated as edits. Lens corrections and manual
perspective import too. Photos last edited with Lightroom's older tone controls (process versions 2003 and 2010) are
converted approximately (Exposure, Fill Light, Recovery, Blacks, Brightness, Contrast, Clarity and the tone curve) and
reported as "Older process version — approximated"; 2012-and-later photos never use those keys.
Every other setting is listed in `LightroomDevelopCoverage` and, when it isn't at its default, shows up in the report as
"not imported" until its panel is mapped. Slider conversions live in `LightroomScales.swift`.

## Fidelity tests

Imported edits are meant to be a close approximation of Lightroom's look, so there is a test that measures it:
`Scripts/fidelity.sh /path/to/fixtures` imports each case's Lightroom settings (`settings.xmp`, a sidecar or a preset), renders
the photo with PixelLoupe at the size of Lightroom's export (`reference.tif`: 16-bit, Display P3, 2048 px), and compares
them with mean and 95th-percentile ΔE2000 and a luminance SSIM. It writes `report.html` with every case's render, the
export and a difference image beside each other, and fails any case over its family's target (mean 3, p95 6 to start; crop
within 1 px, transform within 2). The fixtures are `<family>/<case>/{source.*, settings.xmp, reference.tif}` in a folder outside
the repository (about 40 photos); `Scripts/fetch-fidelity-fixtures.sh` unpacks an archive of them. The same file has the pieces for
tuning `LightroomScales`: `SliderSweepFit` turns a slider sweep (−100…+100 against the PixelLoupe value that matched best) into a
monotone table to paste in. The tests that check this tooling (published ΔE2000 data, SSIM, the report, the sweep fit) run with
the normal suite; the comparison against real exports runs only when `PIXELLOUPE_FIDELITY_DIR` is set.

## Panorama tests

Photo Merge ▸ Panorama is checked in CI on synthetic panoramas (a textured scene photographed by a turning camera).
Its tests on the RAW-95 sample photos (12 overlapping RAW photos, with Lightroom's Spherical and Cylindrical merges of
them) run with `Scripts/panorama.sh [samples] [output]`, or whenever `PIXELLOUPE_PANORAMA_SAMPLES` names the photos'
folder; they stay out of the normal suite because they keep the GPU busy long enough to starve the Develop tests that
wait on renders. They check the alignment, the panorama's size against Lightroom's and how quickly the preview
updates, then merge the photos at full resolution and write the DNGs, a comparison with Lightroom's merges and the
timings (`timings.txt`: how long each step took and the memory used).

## Acknowledgments

Lens profiles come from the [LensFun](https://github.com/lensfun/lensfun) database, licensed under
[CC BY-SA 3.0](https://creativecommons.org/licenses/by-sa/3.0/) and bundled unmodified in
`PixelLoupe/Resources/LensFun` with its license. PixelLoupe implements LensFun's correction models itself and doesn't
include the LensFun library.

## License

PixelLoupe is free and open source under the [MIT License](LICENSE). Material from others that ships with it, or that it
works with, is listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md); the About window shows the same credits.
