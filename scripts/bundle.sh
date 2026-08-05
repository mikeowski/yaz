#!/bin/sh
# Builds yaz.app, and optionally a DMG for distribution.
#
#   ./scripts/bundle.sh          # dist/yaz.app
#   ./scripts/bundle.sh --dmg    # also dist/yaz-<version>.dmg
#
# Why a .app at all: macOS attributes an Accessibility grant to the
# "responsible process". For a CLI run in a terminal that is the terminal —
# the chain observed on this machine was
#
#     cmux.app → login → fish → claude → zsh → yaz
#
# so the prompt asked about cmux.app, the grant did not reach the shells that
# were already running, and none of it was fixable from inside the CLI. As a
# .app, yaz is the responsible process: the prompt says "yaz" and the grant
# survives whatever terminal happens to be open.

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/yaz.app"

die() { printf '✗ %s\n' "$*" >&2; exit 1; }
note() { printf '  %s\n' "$*"; }

[ "$(uname -s)" = "Darwin" ] || die "macOS only"
[ "$(uname -m)" = "arm64" ] || die "Apple Silicon required"
command -v swift >/dev/null 2>&1 || die "swift not found"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$ROOT/Resources/AppInfo.plist" 2>/dev/null || echo 0.1.0)"

# --- build ------------------------------------------------------------------

printf 'building…\n'
cd "$ROOT"
swift build -c release
BUILT="$ROOT/.build/release/yaz"
[ -x "$BUILT" ] || die "build output missing: $BUILT"

# --- bundle ----------------------------------------------------------------

printf 'bundling: %s\n' "$APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BUILT" "$APP/Contents/MacOS/yaz"
cp "$ROOT/Resources/AppInfo.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# --- icon ---
# The icon is drawn by the binary itself, so there is no asset catalogue and
# no checked-in PNGs to drift from the code that draws the menu bar mark.
ICONSET="$(mktemp -d)/yaz.iconset"
if "$BUILT" preview --write-iconset "$ICONSET" >/dev/null 2>&1 \
    && iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/yaz.icns" 2>/dev/null; then
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string yaz' \
        "$APP/Contents/Info.plist" >/dev/null 2>&1 \
        || /usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile yaz' "$APP/Contents/Info.plist"
    note "icon: $(du -h "$APP/Contents/Resources/yaz.icns" | cut -f1)"
else
    note "could not build the icon (not fatal)"
fi
rm -rf "$(dirname "$ICONSET")"

# The binary also carries its own __TEXT,__info_plist section (the identity
# it needs when run as a CLI). Inside a bundle Contents/Info.plist wins; both
# declare the same bundle identifier, so they do not conflict.

# --- sign -------------------------------------------------------------------
#
# Three tiers, best available wins:
#
#   1. Developer ID Application — the real thing. Signed with the Hardened
#      Runtime so the bundle can be notarised, which is what stops Gatekeeper
#      calling it unidentified on someone else's Mac.
#   2. A local self-signed certificate — no Gatekeeper standing, but a *stable*
#      identity, which is what makes a TCC grant survive a rebuild.
#   3. Ad-hoc — identity changes every build, so macOS permissions reset every
#      time. Last resort.
ENTITLEMENTS="$ROOT/Resources/yaz.entitlements"

DEVELOPER_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 \
    | sed -E 's/.*"(Developer ID Application: [^"]+)".*/\1/')"

if [ -n "$DEVELOPER_ID" ]; then
    # --timestamp contacts Apple's timestamp server. Without it the signature
    # stops validating the day the certificate expires, rather than staying
    # valid for everything signed while it was live — and notarisation refuses
    # an untimestamped bundle outright.
    SIGN_ERR="$(codesign --force --deep --timestamp \
        --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --sign "$DEVELOPER_ID" "$APP" 2>&1)" \
        || die "signing with Developer ID failed:
$SIGN_ERR"
    note "signed: $DEVELOPER_ID"
    note "hardened runtime on — ready to notarise (./scripts/notarize.sh)"
    SIGNED_FOR_RELEASE=1
else
    IDENTITY="$("$ROOT/scripts/signing-identity.sh" --check 2>/dev/null || true)"
    if [ -z "$IDENTITY" ] && [ "${YAZ_NO_CERT:-0}" != "1" ]; then
        IDENTITY="$("$ROOT/scripts/signing-identity.sh" 2>/dev/null || true)"
    fi

    if [ -n "$IDENTITY" ]; then
        # Hardened runtime here too: it costs nothing locally and means the
        # entitlements are exercised on every build rather than only at release,
        # when a missing one is expensive to discover.
        #
        # Written as an explicit `if !` rather than `cmd && a || b`, and the
        # error is *shown* rather than swallowed. The chained form silently fell
        # back to ad-hoc once here, and because the real message went to
        # /dev/null the only symptom was permissions resetting on every rebuild
        # — a slow, confusing failure to trace back to this line.
        # Output is captured rather than piped: the exit status of `cmd | sed`
        # is sed's, which is always 0, so a pipeline here would report success
        # no matter what codesign did.
        if SIGN_ERR="$(codesign --force --deep --options runtime \
               --entitlements "$ENTITLEMENTS" \
               --sign "$IDENTITY" "$APP" 2>&1)"
        then
            note "signed: $IDENTITY (stable across rebuilds, not notarisable)"
        else
            printf '%s\n' "$SIGN_ERR" | sed 's/^/    /'
            note "signing with '$IDENTITY' failed — see the error above"
            codesign --force --deep --sign - "$APP" >/dev/null 2>&1 \
                || die "ad-hoc signing failed too"
            note "fell back to ad-hoc — permissions will reset on every rebuild"
        fi
    else
        codesign --force --deep --options runtime \
            --entitlements "$ENTITLEMENTS" --sign - "$APP" 2>/dev/null \
            || codesign --force --deep --sign - "$APP" 2>/dev/null \
            || note "could not sign (not fatal)"
        note "ad-hoc signature — macOS permissions reset on every rebuild"
        note "run ./scripts/signing-identity.sh once to stop that"
    fi
    SIGNED_FOR_RELEASE=0
fi

codesign -dv "$APP" 2>&1 | grep -E '^(Identifier|Authority|Signature|TeamIdentifier)' | sed 's/^/  /' || true

# A signature that does not verify is worse than none: it fails at the user's
# machine instead of here.
codesign --verify --deep --strict "$APP" 2>&1 | sed 's/^/  /' || die "signature does not verify"
note "signature verifies"

if [ "$SIGNED_FOR_RELEASE" = "1" ]; then
    # Only meaningful once notarised and stapled; before that it reports
    # "Unnotarized Developer ID", which is the expected state at this point.
    spctl --assess --type execute --verbose "$APP" 2>&1 | sed 's/^/  /' || true
fi

# Does the bundle actually open?
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" >/dev/null \
    || die "can't read Info.plist"
"$APP/Contents/MacOS/yaz" --help >/dev/null 2>&1 || die "the bundled binary does not run"

printf '✓ %s (version %s)\n' "$APP" "$VERSION"

# --- dmg --------------------------------------------------------------------

if [ "${1:-}" = "--dmg" ]; then
    DMG="$DIST/yaz-$VERSION.dmg"
    STAGE="$(mktemp -d)"
    printf 'preparing DMG…\n'

    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    cp "$ROOT/README.md" "$STAGE/OKUBENI.md" 2>/dev/null || true

    rm -f "$DMG"
    hdiutil create -volname "yaz" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG" \
        || die "hdiutil failed"
    rm -rf "$STAGE"

    printf '✓ %s (%s)\n' "$DMG" "$(du -h "$DMG" | cut -f1)"
    note "to install: open the DMG and drag yaz.app to Applications"
    note "unsigned for distribution — the first open may need right-click → Open"
fi
