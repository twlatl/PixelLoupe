#!/bin/zsh
# Builds PixelLoupe for distribution: archives a Release build signed with Developer ID, packages it in
# a disk image with an Applications shortcut, then notarizes and staples the disk image. The release
# workflow (.github/workflows/release.yml) runs it for each version tag; it runs on a Mac too.
#
#   Scripts/release.sh <version> [<name>] [<output folder>]
#
# <version> is the app's version (CFBundleShortVersionString), such as 1.2.0. <name> labels the disk
# image, PixelLoupe-<name>.dmg (default: the version; a prerelease tag's 1.2.0-beta.1). The output
# folder (default build/release) gets the disk image and its SHA-256 checksum.
#
# The build number (CFBundleVersion) is the UTC time of the build to the minute, such as 202610181432, so
# each build's is higher than every earlier one's, whatever happens to the repository or CI.
#
# Signing and notarizing, from the environment:
#   SIGNING_IDENTITY  The certificate to sign with (default "Developer ID Application"). "-" signs ad hoc
#                     for a dry run on a Mac without the certificate; nothing is notarized then.
#   KEYCHAIN          The keychain holding the certificate, when it isn't in the search list's default.
#   NOTARY_PROFILE    The notarytool keychain profile to notarize with (default PixelLoupe). Save it once with
#                       xcrun notarytool store-credentials PixelLoupe --key AuthKey_<ID>.p8 --key-id <ID> --issuer <issuer>
#                     (Scripts/setup-release-secrets.sh offers to). The GitHub secrets only reach the release workflow.
#   NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER
#                     Or an App Store Connect API key (the .p8 file, its ID and the issuer ID), as the workflow uses.
#   NOTARIZE=0        Sign the disk image but don't notarize it. Otherwise the script stops before building if it
#                     can't sign in to the notary service.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -lt 1 || ! "$1" =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' ]]; then
  print -u2 "usage: Scripts/release.sh <version, such as 1.2.0> [<name>] [<output folder>]"
  exit 64
fi
version="$1"
name="${2:-$version}"
output="${3:-build/release}"
build=$(date -u +%Y%m%d%H%M)
identity="${SIGNING_IDENTITY:-Developer ID Application}"
adhoc=$([[ "$identity" == "-" ]] && print 1 || print 0)
# The project's team, which the Developer ID certificate belongs to.
team=$(sed -nE 's/^[[:space:]]*DEVELOPMENT_TEAM = ([A-Z0-9]+);/\1/p' PixelLoupe.xcodeproj/project.pbxproj | head -1)

work=$(mktemp -d "${TMPDIR:-/tmp}/PixelLoupe-release.XXXXXX")
trap 'hdiutil detach -quiet "$work/mount" 2>/dev/null || true; rm -rf "$work"' EXIT
mkdir -p "$output"
dmg="$output/PixelLoupe-$name.dmg"
step() { print "\n▸ $1" }

# Sign in to the notary service before building, so missing or wrong credentials don't surface after the build.
# (notarytool history only lists past submissions.)
credentials=()
if (( ! adhoc )) && [[ "${NOTARIZE:-1}" != 0 ]]; then
  if [[ -n "${NOTARY_KEY:-}" ]]; then
    credentials=(--key "$NOTARY_KEY" --key-id "${NOTARY_KEY_ID:-}" --issuer "${NOTARY_ISSUER:-}")
    using="the API key in NOTARY_KEY"
  else
    credentials=(--keychain-profile "${NOTARY_PROFILE:-PixelLoupe}")
    using="the keychain profile \"${NOTARY_PROFILE:-PixelLoupe}\""
  fi
  if ! signin=$(xcrun notarytool history "${credentials[@]}" 2>&1); then
    print -u2 "Can't notarize: signing in to Apple's notary service with $using failed:"
    print -r -- "$signin" | sed 's/^/  /' >&2
    print -u2 ""
    print -u2 "The GitHub secrets only reach the release workflow. To notarize on this Mac, save the API key in your"
    print -u2 "keychain once (or let Scripts/setup-release-secrets.sh do it):"
    print -u2 "  xcrun notarytool store-credentials PixelLoupe --key AuthKey_<KEY ID>.p8 --key-id <KEY ID> --issuer <ISSUER ID>"
    print -u2 "then run this again. Add NOTARIZE=0 to build a signed disk image without notarizing it."
    exit 1
  fi
fi

# Developer ID signatures need a secure timestamp (notarization checks for it); ad hoc ones can't have one.
sign_flags=()
(( adhoc )) || sign_flags+=(--timestamp)
[[ -n "${KEYCHAIN:-}" ]] && sign_flags+=(--keychain "$KEYCHAIN")

step "Archiving PixelLoupe $version ($build) (Release, signed by \"$identity\")"
xcodebuild archive \
  -project PixelLoupe.xcodeproj -scheme PixelLoupe -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$work/PixelLoupe.xcarchive" \
  -derivedDataPath "$work/DerivedData" \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM="$( (( adhoc )) || print "$team")" \
  OTHER_CODE_SIGN_FLAGS="${sign_flags[*]}" \
  -quiet
app="$work/PixelLoupe.xcarchive/Products/Applications/PixelLoupe.app"

step "Checking the app's signature"
codesign --verify --deep --strict --verbose=2 "$app"
if (( ! adhoc )); then
  details=$(codesign --display --verbose=2 "$app" 2>&1)
  [[ "$details" == *"Authority=Developer ID Application"* ]] || { print -u2 "Not signed with Developer ID:\n$details"; exit 1 }
  [[ "$details" == *"Timestamp="* ]] || { print -u2 "The signature has no secure timestamp."; exit 1 }
  [[ "$(codesign --display --verbose=4 "$app" 2>&1)" == *"(runtime)"* ]] || { print -u2 "The hardened runtime is off."; exit 1 }
fi
# A debugger entitlement would fail notarization (and shouldn't ship).
if codesign --display --entitlements - --xml "$app" 2>/dev/null | grep -q get-task-allow; then
  print -u2 "The app has the get-task-allow entitlement (a Debug build?)."
  exit 1
fi
shipped=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
[[ "$shipped" == "$version" ]] || { print -u2 "The app says it's version $shipped, not $version."; exit 1 }
shipped_build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$app/Contents/Info.plist")
[[ "$shipped_build" == "$build" ]] || { print -u2 "The app says it's build $shipped_build, not $build."; exit 1 }

step "Making $dmg"
mkdir "$work/image"
ditto "$app" "$work/image/PixelLoupe.app"
ln -s /Applications "$work/image/Applications"
rm -f "$dmg"
diskutil image create from --format UDZO --volumeName "PixelLoupe $name" "$work/image" "$dmg" > /dev/null
(( adhoc )) || codesign --sign "$identity" "${sign_flags[@]}" "$dmg"

if (( ${#credentials} )); then
  step "Notarizing with $using (this usually takes a few minutes)"
  xcrun notarytool submit "$dmg" "${credentials[@]}" --wait --timeout 1h --output-format json > "$work/notary.json"
  submission=$(plutil -extract id raw -o - "$work/notary.json")
  notary_status=$(plutil -extract status raw -o - "$work/notary.json")
  if [[ "$notary_status" != "Accepted" ]]; then
    print -u2 "Notarization finished as \"$notary_status\". Apple's log:"
    xcrun notarytool log "$submission" "${credentials[@]}" >&2 || true
    exit 1
  fi
  print "Accepted ($submission)"

  step "Stapling the notarization ticket"
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  # What Gatekeeper will say to someone who downloads it.
  spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
  hdiutil attach -quiet -nobrowse -readonly -mountpoint "$work/mount" "$dmg"
  spctl --assess --type execute --verbose=2 "$work/mount/PixelLoupe.app"
  hdiutil detach -quiet "$work/mount"
elif (( ! adhoc )); then
  print "\nNot notarized (NOTARIZE=0): Gatekeeper will block this disk image on other Macs."
fi

(cd "$output" && shasum -a 256 "${dmg:t}" > "${dmg:t}.sha256")
step "Done"
print "$dmg"
cat "$dmg.sha256"
