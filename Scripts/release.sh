#!/bin/zsh
# Builds PixelLoupe for distribution: archives a Release build signed with Developer ID, packages it in
# a disk image with an Applications shortcut, then notarizes and staples the disk image. The release
# workflow (.github/workflows/release.yml) runs it for each version tag; it runs on a Mac too.
#
#   Scripts/release.sh <version> [<name>] [<output folder>]
#
# <version> is the app's version (CFBundleShortVersionString), such as 1.2.0. <name> labels the disk
# image, PixelLoupe-<name>.dmg (default: the version; a prerelease tag's 1.2.0-beta.1). The output
# folder (default build/release) gets the disk image, its SHA-256 checksum and, when it's notarized,
# PixelLoupe-<name>.appcast.json for the update feed (below).
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
#
# Updates (Sparkle): a notarized disk image is also signed with the EdDSA key whose public half is SUPublicEDKey in
# Config/Info.plist, which Sparkle checks before installing it. PixelLoupe-<name>.appcast.json records its version,
# size and signature, for the Publish Appcast workflow (.github/workflows/appcast.yml) to write the update feed from.
#   SPARKLE_KEY_FILE  The private key, as generate_keys -x exports it (the release workflow's). Otherwise it's read
#                     from the keychain (account net.pixegen.PixelLoupe), where Scripts/setup-release-secrets.sh
#                     makes it.
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

# Sparkle's tools (sign_update) come with its Swift package, resolved into this build's own DerivedData. A notarized
# build is an update, so check the Sparkle key before building too: sign a small file and verify it with SUPublicEDKey.
sparkle_bin="$work/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
sparkle_account=net.pixegen.PixelLoupe
public_key=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" Config/Info.plist 2>/dev/null || true)
sparkle_key=()
if (( ${#credentials} )); then
  if [[ -z "$public_key" ]]; then
    print -u2 "Can't sign the update for Sparkle: Config/Info.plist has no SUPublicEDKey."
    print -u2 "Scripts/setup-release-secrets.sh makes the key and adds it (then commit Config/Info.plist)."
    exit 1
  fi
  if [[ -n "${SPARKLE_KEY_FILE:-}" ]]; then
    [[ -s "$SPARKLE_KEY_FILE" ]] || { print -u2 "SPARKLE_KEY_FILE ($SPARKLE_KEY_FILE) is missing or empty."; exit 1 }
    sparkle_key=(--ed-key-file "$SPARKLE_KEY_FILE")
    key_source="SPARKLE_KEY_FILE"
  else
    sparkle_key=(--account "$sparkle_account")
    key_source="the keychain's $sparkle_account key"
  fi
  xcodebuild -resolvePackageDependencies -project PixelLoupe.xcodeproj -scheme PixelLoupe \
    -derivedDataPath "$work/DerivedData" -quiet
  print PixelLoupe > "$work/probe"
  if ! probe=$("$sparkle_bin/sign_update" "${sparkle_key[@]}" -p "$work/probe" 2>&1) \
     || ! xcrun swift Scripts/verify-update-signature.swift "$work/probe" "$probe" "$public_key" > /dev/null 2>&1; then
    print -u2 "Can't sign the update for Sparkle with $key_source: it's missing, or it isn't the key whose public half"
    print -u2 "is SUPublicEDKey in Config/Info.plist ($public_key)."
    [[ "$probe" == *[[:space:]]* ]] && print -r -- "$probe" | sed 's/^/  /' >&2
    print -u2 "Scripts/setup-release-secrets.sh makes the key, or exports it for the release workflow."
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

# Sparkle's helpers come signed ad hoc, so they're signed again with the app's identity (notarization needs every
# executable signed with Developer ID, a timestamp and the hardened runtime), innermost first, then the app. The XPC
# services are only for sandboxed apps, which PixelLoupe isn't, so they're left out.
step "Signing Sparkle"
sparkle="$app/Contents/Frameworks/Sparkle.framework"
rm -rf "$sparkle/XPCServices" "$sparkle/Versions/B/XPCServices"
resign() { codesign --force --sign "$identity" --options runtime "${sign_flags[@]}" "$@" }
resign "$sparkle/Versions/B/Autoupdate"
resign "$sparkle/Versions/B/Updater.app"
resign "$sparkle"
resign --preserve-metadata=entitlements,requirements,flags "$app"

step "Checking the app's signature"
codesign --verify --deep --strict --verbose=2 "$app"
if (( ! adhoc )); then
  for code in "$app" "$sparkle" "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app"; do
    details=$(codesign --display --verbose=4 "$code" 2>&1)
    [[ "$details" == *"Authority=Developer ID Application"* && "$details" == *"Timestamp="* && "$details" == *"(runtime)"* ]] \
      || { print -u2 "${code#$work/} isn't signed with Developer ID, a timestamp and the hardened runtime:\n$details"; exit 1 }
  done
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
# APFS with LZFSE compression (ULFO), which Sparkle recommends: quicker to open than zlib's UDZO.
diskutil image create from --format ULFO --volumeName "PixelLoupe $name" "$work/image" "$dmg" > /dev/null
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

  # After stapling, which changes the file: the signature is over the disk image as it's downloaded.
  step "Signing the update for Sparkle"
  signature=$("$sparkle_bin/sign_update" "${sparkle_key[@]}" -p "$dmg")
  # The check Sparkle makes before installing it.
  xcrun swift Scripts/verify-update-signature.swift "$dmg" "$signature" "$public_key"
  minimum=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$app/Contents/Info.plist")
  [[ "$minimum" == *.*.* ]] || minimum+=".0"
  cat > "$output/PixelLoupe-$name.appcast.json" <<JSON
{
  "shortVersion": "$version",
  "version": "$build",
  "minimumSystemVersion": "$minimum",
  "file": "${dmg:t}",
  "length": $(stat -f %z "$dmg"),
  "edSignature": "$signature"
}
JSON
elif (( ! adhoc )); then
  print "\nNot notarized (NOTARIZE=0): Gatekeeper will block this disk image on other Macs."
fi

(cd "$output" && shasum -a 256 "${dmg:t}" > "${dmg:t}.sha256")
step "Done"
print "$dmg"
cat "$dmg.sha256"
if [[ -f "$output/PixelLoupe-$name.appcast.json" ]]; then print "$output/PixelLoupe-$name.appcast.json"; fi
