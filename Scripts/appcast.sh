#!/bin/bash
# Writes Sparkle's update feed (appcast.xml) for one release to standard output:
#
#   Scripts/appcast.sh <PixelLoupe-<name>.appcast.json> <tag> <release notes file> [<published, as ISO 8601>]
#
# The JSON comes from Scripts/release.sh: the version, build number, minimum macOS, file name, size and EdDSA
# signature of the release's disk image. The notes are the published GitHub release's Markdown, which Sparkle 2.9 and
# later shows in its update window. The Publish Appcast workflow (.github/workflows/appcast.yml) attaches the result
# to the release, where the app looks for it (SUFeedURL: the latest release's appcast.xml).
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "usage: Scripts/appcast.sh <metadata.json> <tag> <release notes file> [<published>]" >&2
  exit 64
fi
metadata="$1"
tag="$2"
notes_file="$3"
published="${4:-}"
repository="${GITHUB_REPOSITORY:-twlatl/PixelLoupe}"

field() { jq -er --arg key "$1" '.[$key] | tostring' "$metadata"; }
short_version=$(field shortVersion)
version=$(field version)
minimum=$(field minimumSystemVersion)
file=$(field file)
length=$(field length)
signature=$(field edSignature)

# Everything that goes into the XML outside the notes is checked to need no escaping.
check() { [[ "$2" =~ $3 ]] || { echo "appcast.sh: unexpected $1: $2" >&2; exit 1; }; }
check "version" "$short_version" '^[0-9]+(\.[0-9]+){1,2}$'
check "build number" "$version" '^[0-9]+$'
check "minimum macOS" "$minimum" '^[0-9]+(\.[0-9]+){1,2}$'
check "file name" "$file" '^PixelLoupe-[0-9A-Za-z.-]+\.dmg$'
check "size" "$length" '^[0-9]+$'
check "signature" "$signature" '^[A-Za-z0-9+/]+={0,2}$'
check "tag" "$tag" '^v[0-9A-Za-z.-]+$'
check "repository" "$repository" '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'

# RFC 822, as RSS wants: GNU date on the workflow's Linux runner, BSD date on a Mac (whose -d means something else).
rfc822='+%a, %d %b %Y %H:%M:%S +0000'
if [[ -z "$published" ]]; then
  pub_date=$(LC_ALL=C date -u "$rfc822")
elif date --version > /dev/null 2>&1; then
  pub_date=$(LC_ALL=C date -u -d "$published" "$rfc822")
else
  pub_date=$(LC_ALL=C date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$published" "$rfc822")
fi

releases="https://github.com/$repository/releases"
notes=$(cat "$notes_file")
# A CDATA section ends at the first ]]>, so one in the notes is split across two sections.
notes=${notes//]]>/]]]]><![CDATA[>}

cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>PixelLoupe</title>
    <link>$releases</link>
    <description>New versions of PixelLoupe.</description>
    <language>en</language>
    <item>
      <title>PixelLoupe $short_version</title>
      <link>$releases/tag/$tag</link>
      <pubDate>$pub_date</pubDate>
      <sparkle:version>$version</sparkle:version>
      <sparkle:shortVersionString>$short_version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$minimum</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$releases</sparkle:fullReleaseNotesLink>
XML
if [[ -n "${notes//[[:space:]]/}" ]]; then
  printf '      <description sparkle:format="markdown"><![CDATA[%s]]></description>\n' "$notes"
fi
cat <<XML
      <enclosure url="$releases/download/$tag/$file" length="$length" type="application/octet-stream" sparkle:edSignature="$signature"/>
    </item>
  </channel>
</rss>
XML
