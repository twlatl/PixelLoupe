#!/bin/zsh
# Downloads and unpacks the fidelity fixtures (photos, settings and Lightroom exports) into a folder.
#
#   PIXELLOUPE_FIDELITY_URL=https://…/fidelity-fixtures.tar.gz Scripts/fetch-fidelity-fixtures.sh ~/Fidelity
#
# There is no public copy: build the set in Lightroom (about 40 photos; see Scripts/fidelity.sh for the layout)
# and host the archive wherever you keep large files.
set -euo pipefail

url="${PIXELLOUPE_FIDELITY_URL:?set PIXELLOUPE_FIDELITY_URL to the fixtures archive}"
destination="${1:?usage: Scripts/fetch-fidelity-fixtures.sh /empty/destination/folder}"

# Downloaded files are untrusted: unpack into a new, empty folder and never run anything from it.
if [[ -e "$destination" && -n "$(ls -A "$destination" 2>/dev/null)" ]]; then
  echo "$destination is not empty" >&2
  exit 1
fi
mkdir -p "$destination"
curl --fail --location --output "$destination/fixtures.tar.gz" "$url"
tar -xzf "$destination/fixtures.tar.gz" -C "$destination"
rm "$destination/fixtures.tar.gz"
echo "Fixtures in $destination. Run: Scripts/fidelity.sh $destination"
