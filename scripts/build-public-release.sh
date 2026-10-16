#!/bin/zsh
# Build only the audited Git snapshot, in a path that contains no user's name.
set -eu
MORA_RELEASE_PROJECT="${0:A:h:h}"
cd "$MORA_RELEASE_PROJECT"
MORA_RELEASE_REF="${1:-HEAD}"
python3 scripts/check-publication.py --tree "$MORA_RELEASE_REF"
MORA_RELEASE_TEMP="$(mktemp -d /private/tmp/mora-public-release.XXXXXX)"
trap 'rm -rf -- "$MORA_RELEASE_TEMP"' EXIT
mkdir -p "$MORA_RELEASE_TEMP/source"
git archive "$MORA_RELEASE_REF" | tar -x -C "$MORA_RELEASE_TEMP/source"
MORA_BUILD_ROOT="$MORA_RELEASE_TEMP/package" zsh "$MORA_RELEASE_TEMP/source/scripts/build-app.sh"
python3 scripts/check-publication.py --bundle "$MORA_RELEASE_TEMP/package/Mora.app"
python3 scripts/package-public-release.py "$MORA_RELEASE_TEMP/package/Mora.app" "$MORA_RELEASE_PROJECT/build/releases"
