# Contributing to PixelLoupe

Thanks for helping. PixelLoupe is a raw photo editor and catalog for the Mac, modeled on Lightroom Classic, and it's
free and open source under the [MIT License](LICENSE).

## Reporting bugs and asking for features

Use [GitHub Issues](https://github.com/twlatl/PixelLoupe/issues/new/choose) and pick **Bug report** or **Feature
request**. Search first: someone may have asked already.

- For a bug, say what you did, what you expected and what happened, plus your macOS version, PixelLoupe version
  (PixelLoupe ▸ About PixelLoupe) and, for photo problems, the camera and file type. A sample file helps a lot when
  you can share one.
- For a feature, say what you're trying to do. If Lightroom Classic does it, say how it works there: PixelLoupe follows
  Lightroom's behavior and shortcuts where it has the same feature.

**Security problems** don't go in public issues; see [SECURITY.md](SECURITY.md).

The maintainer plans work in a private tracker, so an accepted issue may be linked to a `RAW-<n>` ticket; the issue is
updated when the work lands.

## Changing the code

1. **Read [SKILLS.md](SKILLS.md) first.** It has the project's rules: macOS 27 minimum, Human Interface Guidelines and
   native controls, performance (nothing blocking the main thread), Lightroom's keyboard shortcuts, non-destructive
   and undoable edits, tests for new behavior, no build warnings.
2. For anything bigger than a small fix, open an issue first so we can agree on the approach.
3. Build and test (see the [README](README.md#building)); the full suite must pass:

   ```sh
   xcodebuild -project PixelLoupe.xcodeproj -scheme PixelLoupe -destination 'platform=macOS' test
   ```

   A few timing-sensitive tests (Navigator zoom, render waits, the large-catalog performance test) can fail on a busy
   machine; rerun them on their own before treating a failure as real.
4. Open a pull request against `main`. Describe what changed and why, how you tested it, what you didn't test, and
   what a reviewer should check by hand. Update the README for any new shortcut or user-facing behavior.

`main` is protected: every change goes through a pull request.

## Third-party code and data

Don't add dependencies, datasets or assets without discussing it first. Anything added must have a license compatible
with distributing PixelLoupe under the MIT License, and gets an entry in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)
and the About window's credits.

## Conduct

Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).
