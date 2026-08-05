#!/bin/sh
# Notarise and staple yaz.app, then build and notarise the DMG.
#
# Signing proves who built it. Notarising is Apple scanning that build and
# recording the result — without it Gatekeeper still refuses the app on anyone
# else's Mac ("Unnotarized Developer ID"), no matter how valid the signature.
#
# Stapling attaches the notarisation ticket to the file so it works offline. It
# is done twice on purpose: to the .app first, then to the DMG built from the
# stapled app. Stapling only the DMG leaves the app unstapled once dragged out,
# which then needs a network round trip on first launch.
#
#   ./scripts/notarize.sh              # app + DMG, notarised and stapled
#   ./scripts/notarize.sh --app-only   # skip the DMG
#
# Credentials, once:
#
#   xcrun notarytool store-credentials yaz \
#       --apple-id <your-apple-id> \
#       --team-id <TEAMID> \
#       --password <app-specific-password>
#
# The app-specific password comes from appleid.apple.com → Sign-In and
# Security → App-Specific Passwords. Your account password will not work, and
# the dashes are part of the password.
#
# "HTTP 401 — The account does not exist" almost never means the password is
# wrong. It means the Apple ID is not the one enrolled in the Developer
# Program. The address you receive mail at and the address the account is
# registered under are often different; developer.apple.com/account shows the
# real one.
#
# An App Store Connect API key avoids the Apple ID entirely and is the better
# choice for CI, since it carries no personal account and can be revoked on its
# own. Same profile name, so nothing below changes:
#
#   xcrun notarytool store-credentials yaz \
#       --key <AuthKey_XXXX.p8> --key-id <KEYID> --issuer <ISSUER-UUID>

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/yaz.app"
PROFILE="${YAZ_NOTARY_PROFILE:-yaz}"

die() { printf '✗ %s\n' "$*" >&2; exit 1; }
note() { printf '  %s\n' "$*"; }

# Staple, retrying on the gap between "Accepted" and the ticket being fetchable.
#
# notarytool returning Accepted means Apple finished scanning, not that the
# ticket has reached the servers stapler downloads it from. Stapling
# immediately afterwards fails with error 73 — "could not validate ticket" —
# which reads like a rejected build and is not one. Observed here: the first
# attempt failed, the second succeeded 15 seconds later.
staple_with_retry() {
    target="$1"
    attempt=1
    while [ "$attempt" -le 6 ]; do
        if xcrun stapler staple "$target" >/dev/null 2>&1; then
            note "stapled: $(basename "$target")"
            return 0
        fi
        [ "$attempt" -eq 1 ] && note "ticket not published yet, retrying…"
        attempt=$((attempt + 1))
        sleep 15
    done
    die "stapling $(basename "$target") failed after 6 attempts over 90 s.
   'xcrun stapler staple -v $target' shows the underlying error."
}

[ -d "$APP" ] || die "no bundle at $APP — run ./scripts/bundle.sh first"

# --- preflight --------------------------------------------------------------

AUTHORITY="$(codesign -dvv "$APP" 2>&1 | grep '^Authority=' | head -1 | cut -d= -f2-)"
case "$AUTHORITY" in
    "Developer ID Application"*) ;;
    *) die "signed with '$AUTHORITY' — notarisation needs a Developer ID Application certificate.
   Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application,
   then re-run ./scripts/bundle.sh" ;;
esac

# Notarisation rejects a bundle without the Hardened Runtime, and the message
# it returns is far less clear than this one.
codesign -d --entitlements :- "$APP" >/dev/null 2>&1 || true
if ! codesign -dvv "$APP" 2>&1 | grep -q "flags=.*runtime"; then
    die "the bundle is not signed with the Hardened Runtime — notarisation will reject it"
fi

TEAM_ID="$(codesign -dvv "$APP" 2>&1 | grep '^TeamIdentifier=' | cut -d= -f2)"
note "identity: $AUTHORITY"
note "team:     $TEAM_ID"

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    die "no notarytool credentials stored under profile '$PROFILE'.
   Create them once with:
     xcrun notarytool store-credentials $PROFILE \\
         --apple-id <your-apple-id> --team-id $TEAM_ID \\
         --password <app-specific-password>
   The app-specific password comes from appleid.apple.com, not your account
   password. If that returns 'HTTP 401 — the account does not exist', the Apple
   ID is the wrong one, not the password: developer.apple.com/account shows the
   address the Developer Program is actually registered under."
fi

# --- notarise the app -------------------------------------------------------
#
# notarytool takes a zip, a dmg or a pkg — not a bare .app — and the zip has to
# be made with ditto so the bundle's symlinks and metadata survive.

printf 'notarising the app…\n'
ZIP="$DIST/yaz-app.zip"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait \
    || die "notarisation failed — 'xcrun notarytool log <id> --keychain-profile $PROFILE' shows why"
rm -f "$ZIP"

staple_with_retry "$APP"

# The real test: this is what Gatekeeper does on someone else's Mac.
spctl --assess --type execute --verbose "$APP" 2>&1 | sed 's/^/  /'
xcrun stapler validate "$APP" >/dev/null 2>&1 && note "ticket validates offline"

[ "${1:-}" = "--app-only" ] && { printf '✓ app notarised and stapled\n'; exit 0; }

# --- dmg --------------------------------------------------------------------
#
# Built *after* stapling so the app inside carries its own ticket. Then the DMG
# is notarised and stapled in turn, so the download itself opens cleanly.

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$APP/Contents/Info.plist")"
DMG="$DIST/yaz-$VERSION.dmg"

printf 'building the DMG from the stapled app…\n'
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "yaz" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG" \
    || die "hdiutil failed"
rm -rf "$STAGE"

# The DMG carries the same signature as the app it ships.
codesign --force --sign "$AUTHORITY" --timestamp "$DMG" || die "signing the DMG failed"

printf 'notarising the DMG…\n'
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait \
    || die "notarising the DMG failed"
staple_with_retry "$DMG"

printf '✓ %s (%s) — notarised and stapled\n' "$DMG" "$(du -h "$DMG" | cut -f1)"
note "this opens on any Mac with no Gatekeeper warning and no right-click → Open"
