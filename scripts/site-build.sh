#!/bin/sh
# Build command of the Cloudflare Worker "yaz" (Workers Builds, connected to this repository). Cloudflare runs
# `sh scripts/site-build.sh` on every push to main, then `npx wrangler deploy`, so the site goes live without a Mac.
#
# The release downloads (the DMG, latest.json and the signed Sparkle feed) are made by scripts/release.sh on the Mac
# and the DMG is never committed. A deploy from a checkout alone would drop them, so this puts them into
# site/downloads first and checks them:
#
# - The feed comes from the live site. It may have no updates in it yet, but every update it lists must carry an
#   EdDSA signature (only the Mac can sign one).
# - The download is the newer of what the live site serves and the latest GitHub release. yaz is public, so a
#   release's DMG and SHA256SUMS.txt are on GitHub, and its version, build and minimum macOS are in
#   Resources/AppInfo.plist at its tag: a release made on the Mac reaches the download button even if its own deploy
#   was overwritten.
# - The DMG must match the SHA-256 it is published with.
#
# Anything missing or wrong stops the build, and Cloudflare keeps the deploy that is live.
# Releases still deploy from the Mac (`scripts/release.sh --deploy`): that is the only way a new version reaches
# the update feed. Avoid pushing to main while a release deploy is uploading: a build that read the old files
# first would put them back (push anything again to fix it).
#
# Runs on Cloudflare's Linux build image and on a Mac. Needs curl and node.
set -eu
cd "$(dirname "$0")/.."

SITE="${SITE_URL:-https://yaz.mike4.dev}"
REPO="${YAZ_REPO:-mikeowski/yaz}"
GITHUB="${GITHUB_URL:-https://github.com}"
API="${GITHUB_API:-https://api.github.com}"
RAW="${GITHUB_RAW:-https://raw.githubusercontent.com}"
APP=yaz
OUT=site/downloads
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf '✗ %s — not deploying, the live site stays as it is\n' "$1" >&2; exit 1; }
get() { curl -fsSL --retry 3 --retry-delay 2 -o "$2" "$1"; }
newer() { # newer A B: A is a higher version than B
  node -e 'const a=process.argv[1].split(".").map(Number), b=process.argv[2].split(".").map(Number);
    for (let i=0;i<3;i++){ if((a[i]||0)!==(b[i]||0)) process.exit((a[i]||0)>(b[i]||0)?0:1); } process.exit(1);' "$1" "$2"
}
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

# --- the live site: manifest and feed ----------------------------------------------------------------------------
printf '› reading the release files on %s\n' "$SITE"
get "$SITE/downloads/latest.json" "$TMP/live.json" || fail "could not fetch $SITE/downloads/latest.json"
get "$SITE/downloads/appcast.xml" "$TMP/appcast.xml" || fail "could not fetch $SITE/downloads/appcast.xml"
grep -q '<rss' "$TMP/appcast.xml" || fail "the live appcast.xml is not a feed"
ITEMS="$(grep -c '<enclosure' "$TMP/appcast.xml" || true)"
SIGNED="$(grep -c 'sparkle:edSignature=' "$TMP/appcast.xml" || true)"
[ "$ITEMS" = "$SIGNED" ] || fail "the live feed lists $ITEMS updates but only $SIGNED are signed"
printf '  feed: %s signed update(s)\n' "$ITEMS"

LIVE="$(node -e '
  const m = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  if (!/^yaz-[0-9][0-9A-Za-z.]*\.dmg$/.test(String(m.file || "")) || !/^[0-9a-f]{64}$/.test(String(m.sha256 || "")))
    process.exit(1);
  process.stdout.write(m.version + " " + m.file + " " + m.sha256);
' "$TMP/live.json")" || fail "the live latest.json does not name a yaz DMG with a SHA-256"
set -- $LIVE
VERSION="$1"; FILE="$2"; SHA="$3"
printf '  live site: yaz %s\n' "$VERSION"

# --- the latest GitHub release -------------------------------------------------------------------------------------
RELEASE="$(curl -fsSL --retry 2 "$API/repos/$REPO/releases/latest" 2>/dev/null | node -e '
  let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
    try { const r = JSON.parse(s); process.stdout.write(String(r.tag_name || "").replace(/^v/, "") + " " + (r.published_at || "")); }
    catch { }
  });' || true)"
RELEASED="${RELEASE%% *}"
PUBLISHED="${RELEASE#* }"

if [ -n "$RELEASED" ] && newer "$RELEASED" "$VERSION"; then
  # Released on GitHub, but the site still serves an older version: build its manifest from the release.
  printf '  GitHub release v%s is newer; taking the download from it\n' "$RELEASED"
  VERSION="$RELEASED"
  FILE="yaz-$VERSION.dmg"
  get "$GITHUB/$REPO/releases/download/v$VERSION/SHA256SUMS.txt" "$TMP/sums" \
    || fail "the GitHub release v$VERSION has no SHA256SUMS.txt"
  SHA="$(awk -v f="$FILE" '$2 == f || $2 == "*" f { print $1 }' "$TMP/sums")"
  printf '%s' "$SHA" | grep -Eq '^[0-9a-f]{64}$' || fail "SHA256SUMS.txt of v$VERSION has no line for $FILE"
  get "$RAW/$REPO/v$VERSION/Resources/AppInfo.plist" "$TMP/info.plist" \
    || fail "could not read Resources/AppInfo.plist at v$VERSION"
  plist() { node -e '
    const s = require("fs").readFileSync(process.argv[1], "utf8");
    const m = s.match(new RegExp("<key>" + process.argv[2] + "</key>\\s*<string>([^<]*)</string>"));
    if (!m) process.exit(1); process.stdout.write(m[1]);' "$TMP/info.plist" "$1"; }
  PLIST_VERSION="$(plist CFBundleShortVersionString)" || fail "AppInfo.plist at v$VERSION has no version"
  [ "$PLIST_VERSION" = "$VERSION" ] || fail "AppInfo.plist at v$VERSION says $PLIST_VERSION"
  BUILD="$(plist CFBundleVersion)" || fail "AppInfo.plist at v$VERSION has no build number"
  MIN_OS="$(plist LSMinimumSystemVersion)" || fail "AppInfo.plist at v$VERSION has no minimum macOS"
  get "$GITHUB/$REPO/releases/download/v$VERSION/$FILE" "$TMP/$FILE" || fail "could not download $FILE from v$VERSION"
  [ "$(sha256 "$TMP/$FILE")" = "$SHA" ] || fail "$FILE does not match SHA256SUMS.txt of v$VERSION"
  SIZE="$(wc -c < "$TMP/$FILE" | tr -d ' ')"
  cat > "$TMP/latest.json" <<JSON
{
  "name": "yaz",
  "version": "$VERSION",
  "build": "$BUILD",
  "file": "$FILE",
  "url": "/downloads/$FILE",
  "sha256": "$SHA",
  "size": $SIZE,
  "minimumSystemVersion": "$MIN_OS",
  "architectures": ["arm64"],
  "notarized": true,
  "releasedAt": "${PUBLISHED:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
}
JSON
  node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$TMP/latest.json" \
    || fail "the manifest built for v$VERSION is not valid JSON"
  if [ "$ITEMS" = 0 ] || ! grep -q "<sparkle:shortVersionString>$VERSION<" "$TMP/appcast.xml"; then
    printf '  note: the update feed has no %s yet; a release deploy from the Mac adds it\n' "$VERSION"
  fi
else
  [ -n "$RELEASED" ] || printf '  note: could not read the latest GitHub release; using the live site as it is\n'
  # The live site's own download: from the site, or from the GitHub release of that version.
  cp "$TMP/live.json" "$TMP/latest.json"
  if ! get "$SITE/downloads/$FILE" "$TMP/$FILE"; then
    printf '  %s is not on the site; taking it from the GitHub release v%s\n' "$FILE" "$VERSION"
    get "$GITHUB/$REPO/releases/download/v$VERSION/$FILE" "$TMP/$FILE" \
      || fail "$FILE is neither on $SITE nor in the GitHub release v$VERSION"
  fi
  [ "$(sha256 "$TMP/$FILE")" = "$SHA" ] || fail "$FILE does not match the SHA-256 in latest.json"
  # A manifest from before 0.2.0 points at GitHub; the site serves its own copy now (site/_redirects).
  node -e '
    const fs = require("fs"), p = process.argv[1], m = JSON.parse(fs.readFileSync(p, "utf8"));
    m.url = "/downloads/" + m.file; fs.writeFileSync(p, JSON.stringify(m, null, 2) + "\n");' "$TMP/latest.json"
fi

# --- into site/downloads -------------------------------------------------------------------------------------------
mkdir -p "$OUT"
find "$OUT" -name "$APP-*.dmg" -delete
cp "$TMP/latest.json" "$TMP/appcast.xml" "$TMP/$FILE" "$OUT/"
cp "$TMP/$FILE" "$OUT/$APP-latest.dmg"
printf '✓ yaz %s ready (%s bytes, checksum matches; feed: %s signed update(s))\n' \
  "$VERSION" "$(wc -c < "$OUT/$FILE" | tr -d ' ')" "$ITEMS"
