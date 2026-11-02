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

REPO="${YAZ_REPO:-mikeowski/yaz}"

# A release is out but its manifest and signed feed are not committed yet:
# deploying this checkout would put the previous version back on the site,
# in the download button and in the update feed. Refuse, so Cloudflare keeps
# the deploy release.sh made. Commit site/downloads/latest.json,
# site/downloads/appcast.xml and site/_redirects from the release, then push.
RELEASED="$(curl -fsSL --retry 2 "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(String(JSON.parse(s).tag_name||"").replace(/^v/,""))}catch{}})' \
    || true)"
COMMITTED="$(field version)"
if [ -n "$RELEASED" ] && node -e '
    const a = process.argv[1].split(".").map(Number), b = process.argv[2].split(".").map(Number);
    for (let i = 0; i < 3; i++) { if ((a[i]||0) !== (b[i]||0)) process.exit((a[i]||0) > (b[i]||0) ? 0 : 1); }
    process.exit(1);' "$RELEASED" "$COMMITTED"; then
    printf 'release v%s is out, but site/downloads/latest.json says %s.\n' "$RELEASED" "$COMMITTED" >&2
    printf 'commit the release files (latest.json, appcast.xml, _redirects) before deploying the site.\n' >&2
    exit 1
fi
[ -n "$RELEASED" ] || printf 'note: could not read the latest GitHub release; deploying anyway\n'

URL="$(field url)"
case "$URL" in
    /downloads/*) ;;
    *) printf 'the download is served from %s — nothing to fetch\n' "$URL"; exit 0 ;;
esac

VERSION="$(field version)"
FILE="$(field file)"
SHA="$(field sha256)"
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
