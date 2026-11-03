#!/usr/bin/env bash
# Builds a signed, notarised yaz release and publishes it: the DMG, the
# download manifest and the signed Sparkle update feed.
#
#   ./scripts/release.sh            # build, notarise, refresh site/downloads
#   ./scripts/release.sh --github   # also a GitHub release v<version>
#   ./scripts/release.sh --deploy   # also the site + update feed (Cloudflare)
#
# Flags combine. The version comes from Resources/AppInfo.plist: raise
# CFBundleShortVersionString, and CFBundleVersion by one, before a release.
# Sparkle compares CFBundleVersion; a release that does not raise it is never
# offered to anyone.
#
# Release notes go in release-notes/<version>.md (committed) or
# dist/notes-<version>.md (Markdown: ## headings, - lists, **bold**, `code`). They become the GitHub release body and the text Sparkle
# shows in its update window.
#
# Needs, once, on the maintainer's Mac:
#   - a Developer ID Application certificate (scripts/bundle.sh picks it up);
#   - notarytool credentials under the profile "yaz" (see scripts/notarize.sh);
#   - the Sparkle EdDSA private key in the login Keychain. The public half is
#     SUPublicEDKey in Resources/AppInfo.plist, and this script refuses to sign
#     a feed with any other key: a feed signed with the wrong key is one every
#     installed copy rejects, and nobody updates again.
#   - for --deploy, `npx wrangler login` once (Cloudflare account of mike4.dev).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

die() { printf '✗ %s\n' "$*" >&2; exit 1; }
note() { printf '  %s\n' "$*"; }

[ "$(uname -s)" = "Darwin" ] || die "macOS only"

PLIST="$ROOT/Resources/AppInfo.plist"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")
MIN_OS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")
FEED=$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$PLIST")
PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST")
SITE_URL="${FEED%/downloads/appcast.xml}"

DIST="$ROOT/dist"
APP="$DIST/yaz.app"
DMG="$DIST/yaz-$VERSION.dmg"
NOTES="$DIST/notes-$VERSION.md"
# Notes may be committed as release-notes/<version>.md; dist/ is not.
if [ ! -f "$NOTES" ] && [ -f "$ROOT/release-notes/$VERSION.md" ]; then
    mkdir -p "$DIST"
    cp "$ROOT/release-notes/$VERSION.md" "$NOTES"
fi
DOWNLOADS="$ROOT/site/downloads"

printf '› yaz %s (%s) → %s\n' "$VERSION" "$BUILD" "$SITE_URL"

# --- preflight ----------------------------------------------------------------
#
# Everything that can fail cheaply fails before the build and the minutes of
# notarisation.

if [[ " $* " == *" --github "* ]]; then
    [ -f "$NOTES" ] || die "write the release notes to $NOTES first"
    git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null \
        || die "tag v$VERSION does not exist — git tag v$VERSION && git push origin v$VERSION"
fi

# The feed must not already announce this build: Sparkle would never offer it.
if [ -f "$DOWNLOADS/appcast.xml" ] \
    && grep -q "<sparkle:version>$BUILD</sparkle:version>" "$DOWNLOADS/appcast.xml"; then
    die "the feed already has build $BUILD — raise CFBundleVersion in $PLIST"
fi

# --- build, sign, notarise ----------------------------------------------------

./scripts/bundle.sh

AUTHORITY="$(codesign -dvv "$APP" 2>&1 | grep '^Authority=' | head -1 | cut -d= -f2-)"
case "$AUTHORITY" in
    "Developer ID Application"*) note "signed: $AUTHORITY" ;;
    *) die "signed with '$AUTHORITY' — a release needs Developer ID (see CONTRIBUTING.md)" ;;
esac

# The icon must be the compiled Icon Composer asset: the drawn fallback has
# no Dark, Clear or Tinted appearance.
[ -f "$APP/Contents/Resources/Assets.car" ] \
    || die "the bundle has no Assets.car — actool did not compile Resources/AppIcon.icon (Xcode 26 needed)"

# A release that cannot update itself strands everyone who installs it.
"$APP/Contents/MacOS/yaz" updates --require | sed 's/^/  /' \
    || die "this build cannot update itself — see the lines above"

./scripts/notarize.sh
[ -f "$DMG" ] || die "notarize.sh did not produce $DMG"

# Gatekeeper's view, as a stranger's Mac sees it.
spctl --assess --type open --context context:primary-signature -v "$DMG" 2>&1 | sed 's/^/  dmg: /'
spctl --assess --type execute -v "$APP" 2>&1 | sed 's/^/  app: /'

SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
SIZE=$(stat -f%z "$DMG")
(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > SHA256SUMS.txt)

# --- the website's download folder --------------------------------------------
#
# Only the current version is served (older DMGs stay in dist/ and on GitHub).
# DMGs are not committed; latest.json and appcast.xml may be (the site build
# copies all three over from the live site either way).

mkdir -p "$DOWNLOADS"
find "$DOWNLOADS" -name 'yaz-*.dmg' -delete
cp "$DMG" "$DOWNLOADS/"
cp "$DMG" "$DOWNLOADS/yaz-latest.dmg"

cat > "$DOWNLOADS/latest.json" <<JSON
{
  "name": "yaz",
  "version": "$VERSION",
  "build": "$BUILD",
  "file": "yaz-$VERSION.dmg",
  "url": "/downloads/yaz-$VERSION.dmg",
  "sha256": "$SHA",
  "size": $SIZE,
  "minimumSystemVersion": "$MIN_OS",
  "architectures": ["arm64"],
  "notarized": true,
  "releasedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

# The stable download URL now serves the DMG from the site itself.
cat > "$ROOT/site/_redirects" <<REDIRECTS
# Stable download URLs. Rewritten by scripts/release.sh on every release.
/download          /downloads/yaz-latest.dmg   302
/download/latest   /downloads/latest.json      302
REDIRECTS

# --- the Sparkle update feed --------------------------------------------------

SPARKLE_BIN="$(find "$ROOT/.build/artifacts" -type d -path '*Sparkle/bin' 2>/dev/null | head -1)"
[ -x "$SPARKLE_BIN/generate_appcast" ] || die "Sparkle's tools are missing from .build/artifacts"

KEYCHAIN_KEY="$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null || true)"
[ -n "$KEYCHAIN_KEY" ] || die "no Sparkle key in the login Keychain — '$SPARKLE_BIN/generate_keys' creates one"
[ "$KEYCHAIN_KEY" = "$PUBLIC_KEY" ] || die "the Keychain's Sparkle key ($KEYCHAIN_KEY) is not
   SUPublicEDKey in $PLIST ($PUBLIC_KEY). Installed copies would reject the feed."

UPDATES="$DIST/updates"
mkdir -p "$UPDATES"
find "$UPDATES" -name 'yaz-*' ! -name "yaz-$VERSION.*" -delete
cp "$DMG" "$UPDATES/"

if [ -f "$NOTES" ]; then
    python3 - "$NOTES" "$UPDATES/yaz-$VERSION.html" <<'PY'
import html, re, sys
lines = open(sys.argv[1]).read().splitlines()
out, in_list, in_code = [], False, False
def inline(t):
    t = html.escape(t)
    t = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", t)
    return re.sub(r"`(.+?)`", r"<code>\1</code>", t)
for line in lines:
    if line.startswith("```"):
        in_code = not in_code
        out.append("<pre>" if in_code else "</pre>")
        continue
    if in_code:
        out.append(html.escape(line)); continue
    if line.startswith("- "):
        if not in_list: out.append("<ul>"); in_list = True
        out.append("<li>" + inline(line[2:]) + "</li>"); continue
    if in_list: out.append("</ul>"); in_list = False
    if line.startswith("## "): out.append("<h3>" + inline(line[3:]) + "</h3>")
    elif line.strip(): out.append("<p>" + inline(line) + "</p>")
if in_list: out.append("</ul>")
open(sys.argv[2], "w").write(
    "<!doctype html><meta charset=utf-8><body style='font: 13px -apple-system'>" + "\n".join(out))
PY
else
    note "no $NOTES — the update window will show no release notes"
fi

printf '› signing the update feed\n'
"$SPARKLE_BIN/generate_appcast" --download-url-prefix "$SITE_URL/downloads/" \
    --embed-release-notes -o "$DOWNLOADS/appcast.xml" "$UPDATES" >/dev/null
grep -q "<sparkle:version>$BUILD</sparkle:version>" "$DOWNLOADS/appcast.xml" \
    || die "the feed does not list build $BUILD"
grep -q 'sparkle:edSignature=' "$DOWNLOADS/appcast.xml" || die "the feed is not signed"

printf '✓ %s (%s, sha256 %s)\n' "$DMG" "$(du -h "$DMG" | cut -f1)" "$SHA"

# --- GitHub release (only when asked) -----------------------------------------

if [[ " $* " == *" --github "* ]]; then
    printf '› publishing GitHub release v%s\n' "$VERSION"
    gh release create "v$VERSION" "$DMG" "$DIST/SHA256SUMS.txt" \
        --title "yaz $VERSION" --notes-file "$NOTES" --verify-tag
fi

# --- the site and the update feed (only when asked) ---------------------------

if [[ " $* " == *" --deploy "* ]]; then
    printf '› deploying the site and the update feed\n'
    npx -y wrangler@4 deploy
fi

# The site deploys itself on every push to main (scripts/site-build.sh copies
# these files over from the live site), so committing them is only for the
# record. It keeps the repository's copies in step with what is live.
if ! git diff --quiet -- site/downloads/latest.json site/downloads/appcast.xml site/_redirects; then
    printf '\n› optional: commit the release files so the repository matches the live site:\n\n'
    printf '    git add site/downloads/latest.json site/downloads/appcast.xml site/_redirects\n'
    printf '    git commit -m "Release %s: download manifest and update feed"\n' "$VERSION"
    printf '    git push origin HEAD:main\n\n'
fi
