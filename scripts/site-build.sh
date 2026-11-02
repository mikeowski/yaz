#!/bin/sh
# The build command of the Cloudflare Worker "yaz" (Workers Builds, connected
# to this repository). Cloudflare runs it on every push to main that touches
# the site, then runs `npx wrangler deploy`.
#
# DMGs are not committed. When site/downloads/latest.json serves the DMG from
# the site itself, this fetches it from the GitHub release of that version and
# checks it against the manifest's SHA-256, so a deploy from a fresh checkout
# never removes the download, or the file every Sparkle update points at.
# Release with `scripts/release.sh --github` before pushing the new manifest.
#
# Runs on Cloudflare's Linux build image and on a Mac. Needs curl and node.

set -eu
cd "$(dirname "$0")/.."

MANIFEST=site/downloads/latest.json
field() { node -e "process.stdout.write(String(require('./$MANIFEST')['$1']))"; }

URL="$(field url)"
case "$URL" in
    /downloads/*) ;;
    *) printf 'the download is served from %s — nothing to fetch\n' "$URL"; exit 0 ;;
esac

VERSION="$(field version)"
FILE="$(field file)"
SHA="$(field sha256)"
REPO="${YAZ_REPO:-mikeowski/yaz}"
TARGET="site/downloads/$FILE"

printf 'fetching %s from the GitHub release v%s\n' "$FILE" "$VERSION"
curl -fsSL --retry 3 -o "$TARGET" \
    "https://github.com/$REPO/releases/download/v$VERSION/$FILE"

if command -v sha256sum >/dev/null 2>&1; then
    ACTUAL="$(sha256sum "$TARGET" | cut -d' ' -f1)"
else
    ACTUAL="$(shasum -a 256 "$TARGET" | cut -d' ' -f1)"
fi
if [ "$ACTUAL" != "$SHA" ]; then
    rm -f "$TARGET"
    printf '✗ %s has SHA-256 %s, the manifest says %s — not deploying\n' "$FILE" "$ACTUAL" "$SHA" >&2
    exit 1
fi

cp "$TARGET" site/downloads/yaz-latest.dmg
printf '✓ %s (%s bytes), checksum matches\n' "$FILE" "$(wc -c < "$TARGET" | tr -d ' ')"
