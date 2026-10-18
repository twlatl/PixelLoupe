# PixelLoupe Project Rules

Rules for anyone — people or AI agents — working on PixelLoupe. Read this before making changes. If a request
conflicts with a rule here, raise it rather than quietly breaking the rule.

## Platform

- **The minimum macOS version is macOS 27.** RAW 9 is the floor for RAW features, and it ships with macOS 27. Don't
  add availability checks or fallbacks for older systems.
- Build with the current Xcode. The project uses Swift 6 with main-actor default isolation.

## Design

- **Follow Apple's Human Interface Guidelines.** PixelLoupe should look and behave like a Mac app.
- **Use Liquid Glass where it makes sense** — toolbars, controls and floating elements that sit over content (for
  example the Library/Develop mode picker). Don't put glass behind content that should read as a flat surface, such
  as the photo grid or the Develop preview.
- **Prefer native controls.** Custom UI that duplicates a native control (buttons, sliders, pop-ups, segmented
  controls, source lists, sheets, menus) is discouraged. Build custom views only where AppKit/SwiftUI has no
  equivalent, such as the color wheels, curve editor and loupe.
- **Use SF Symbols for icons** whenever a suitable symbol exists. Only add custom artwork when nothing in the
  library fits, and keep source files in `Design/`.
- Support light and dark appearance and the user's Matte Color setting; never hard-code colors that assume one theme.
- Every control needs an accessibility label; interactive custom views need an accessibility role.

## Performance

**Speed is paramount.** The app must always feel snappy; scrolling the grid and resizing thumbnails must never feel
clunky. When choosing between designs, prefer the faster one.

- Never decode, render or touch the file system on the main thread in a way that blocks interaction. Use
  `@concurrent` functions for heavy work and hand results back to the main actor.
- The grid draws cached thumbnails through Core Animation layers; don't add per-cell drawing work.
- Render previews at display resolution (e.g. `CIRAWFilter.scaleFactor`), not full resolution, unless the feature
  needs actual pixels (like the loupe at 100%+).
- Keep large lists lazy: fetched-results controllers with batch faulting, diffable data sources, no loading whole
  catalogs into memory.
- If a change could affect scrolling, resizing or slider responsiveness, test it with a large catalog of real RAW
  files before opening a PR.

## Keyboard shortcuts

- **Where PixelLoupe implements a feature Adobe Lightroom Classic also has, use Lightroom's keyboard shortcut** so
  people switching between the apps don't have to relearn them (e.g. G for Grid, D for Develop, 0–5 for ratings,
  P/X/U for flags, C for Compare).
- Single-key shortcuts must not fire while the user is typing in a text field. Handle them through `KeyCommand`
  (window-wide) rather than menu key equivalents without modifiers.
- Document every shortcut in the README's shortcut table.

## Photo edits

- **All edits are non-destructive.** Original files are never modified. Edits are stored per photo in the catalog
  (`Photo.adjustmentsData`) and the user can always revert to the original (Revert to Original / Reset).
- Every edit must be undoable with ⌘Z.
- Rendering of edits goes through the shared pipeline (`DevelopSource` / `AdjustmentPipeline`) so the preview,
  thumbnails, enlarged views and loupe always match.
- Changes to the Core Data model require a new model version and must migrate existing catalogs automatically.

## Code

- Match the surrounding code's style, naming and comment density. AppKit is built in code — no storyboards or nibs.
- Add tests for new behavior (Swift Testing for unit tests, XCTest for UI tests). The full suite must pass with no
  build warnings:

  ```sh
  xcodebuild -project PixelLoupe.xcodeproj -scheme PixelLoupe -destination 'platform=macOS' test
  ```

- Don't let tests or test tooling change the user's real preferences (for example the last opened catalog).

## Git and pull requests

- Branch per Jira ticket, named after the ticket key and summary, e.g. `RAW-6-filmstrip`.
- **Pull requests should be as verbose as possible:** what changed and why, how it works, decisions and trade-offs,
  how it was tested, anything not tested, and anything reviewers should check by hand. Link the Jira ticket, and the
  GitHub issue it fixes if there is one (`Fixes #123`).
- **Don't add a tagline about which AI agent helped write or create the code** in pull requests.
