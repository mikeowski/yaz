#!/bin/sh
# Build command of the Cloudflare Worker "yaz" (Workers Builds, connected to this repository). Cloudflare runs
# `sh scripts/site-build.sh` on every push to main, then `npx wrangler deploy`, so the site goes live without a Mac.
#
# The release downloads (the DMG, latest.json and the signed Sparkle feed) are made by scripts/release.sh on the Mac
# and are not committed. A deploy from a checkout alone would drop them, and with them every installed copy's
# updates. So this copies them from the live site into site/downloads first and checks them: the manifest names a
# DMG of this app, the DMG matches the manifest's SHA-256, the feed carries an EdDSA signature. If anything is
# missing or wrong the build stops, and Cloudflare keeps the deploy that is live.
#
# Releases still deploy from the Mac (`scripts/release.sh --deploy`); the next push carries their files over.
# Avoid pushing to main while a release deploy is uploading: a build that read the old files before the release
# went live would put them back (deploy again, or push anything, to fix it).
#
# Runs on Cloudflare's Linux build image and on a Mac. Needs curl and node.
set -eu
cd "$(dirname "$0")/.."

SITE="${SITE_URL:-https://yaz.mike4.dev}"
APP="yaz"
OUT=site/downloads
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf '✗ %s — not deploying, the live site stays as it is\n' "$1" >&2; exit 1; }
fetch() { curl -fsSL --retry 3 --retry-delay 2 -o "$TMP/$2" "$SITE/downloads/$1" || fail "could not fetch $SITE/downloads/$1"; }

fetch latest.json latest.json
fetch appcast.xml appcast.xml
grep -q 'sparkle:edSignature' "$TMP/appcast.xml" || fail "the live update feed has no EdDSA signature"

# The manifest's DMG: a plain file name of this app, and its checksum.
FIELDS="$(node -e '
  const m = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const app = process.argv[2];
  const file = String(m.file || "");
  if (!new RegExp("^" + app + "-[0-9][0-9A-Za-z.]*\\.dmg$").test(file)) process.exit(1);
  if (!/^[0-9a-f]{64}$/.test(String(m.sha256 || ""))) process.exit(1);
  process.stdout.write(file + " " + m.sha256 + " " + m.version);
' "$TMP/latest.json" "$APP")" || fail "the live latest.json does not name a $APP DMG with a SHA-256"
set -- $FIELDS
FILE="$1"; SHA="$2"; VERSION="$3"

fetch "$FILE" "$FILE"
if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL="$(sha256sum "$TMP/$FILE" | cut -d' ' -f1)"
else
  ACTUAL="$(shasum -a 256 "$TMP/$FILE" | cut -d' ' -f1)"
fi
[ "$ACTUAL" = "$SHA" ] || fail "$FILE has SHA-256 $ACTUAL, latest.json says $SHA"

mkdir -p "$OUT"
find "$OUT" -name "$APP-*.dmg" -delete
cp "$TMP/latest.json" "$TMP/appcast.xml" "$TMP/$FILE" "$OUT/"
cp "$TMP/$FILE" "$OUT/$APP-latest.dmg"
printf '✓ %s %s carried over from %s (%s bytes, checksum matches, feed signed)\n' \
  "$APP" "$VERSION" "$SITE" "$(wc -c < "$OUT/$FILE" | tr -d ' ')"
