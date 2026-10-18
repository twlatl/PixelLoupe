# Security policy

## Reporting a vulnerability

Please don't open a public issue. Report it privately through GitHub: on the repository's **Security** tab, choose
**Report a vulnerability**. Include what's affected, how to reproduce it, and the PixelLoupe and macOS versions.

You'll get a reply within a week. Once a fix is released, the advisory is published with credit to you, unless you'd
rather not be named.

## Supported versions

Only the latest release gets security fixes. Download it from
[GitHub Releases](https://github.com/twlatl/PixelLoupe/releases).

## What's in scope

PixelLoupe reads untrusted files (raw photos, Lightroom catalogs and presets, Adobe profiles, catalog packages), so
crashes or worse from a crafted file are in scope, as are problems with updates (the update feed, signatures) and
with how the app handles your files and folders.
