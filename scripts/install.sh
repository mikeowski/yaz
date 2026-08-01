#!/bin/sh
# yaz installer — builds from source and installs into /usr/local/bin.
#
# Deliberately not a `curl | sh` one-liner: this asks for sudo and installs a
# daemon that will request TCC permissions. Read it before running it.
#
#   ./scripts/install.sh              # build and install
#   ./scripts/install.sh --login      # also enable launch at login
#   ./scripts/install.sh --uninstall  # remove the binary and the login item

set -eu

PREFIX="${PREFIX:-/usr/local/bin}"
TARGET="$PREFIX/yaz"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

die() { printf '✗ %s\n' "$*" >&2; exit 1; }
note() { printf '  %s\n' "$*"; }

# sudo only when it is genuinely needed. If a directory does not exist yet the
# question is whether its *parent* is writable — otherwise installing into
# something like ~/bin asked for a password too.
writable() {
    if [ -d "$1" ]; then [ -w "$1" ]; else [ -w "$(dirname "$1")" ]; fi
}

# --- prerequisites -------------------------------------------------------------

[ "$(uname -s)" = "Darwin" ] || die "yaz only runs on macOS"

# Whisper and Parakeet run on the Apple Neural Engine; on Intel the models
# load but the latency is not usable.
[ "$(uname -m)" = "arm64" ] || die "Apple Silicon required (Intel desteklenmiyor)"

os_major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$os_major" -ge 26 ] || die "macOS 26 or later required (found: $(sw_vers -productVersion))"

command -v swift >/dev/null 2>&1 || die "swift not found — Xcode veya Command Line Tools kur"

# --- uninstall ---------------------------------------------------------------

if [ "${1:-}" = "--uninstall" ]; then
    if [ -x "$TARGET" ]; then
        "$TARGET" install --uninstall 2>/dev/null || true
    fi
    if [ -e "$TARGET" ]; then
        printf 'removing: %s\n' "$TARGET"
        if writable "$PREFIX"; then
            rm -f "$TARGET"
        else
            note "$PREFIX is not writable — asking for sudo"
            sudo rm -f "$TARGET"
        fi
    fi
    printf '✓ yaz removed\n'
    note "models remain in ~/Documents/huggingface — delete them by hand if you want"
    note "settings remain in ~/.config/yaz/config.json"
    exit 0
fi

# --- build ------------------------------------------------------------------

printf 'building…\n'
cd "$ROOT"
swift build -c release

BUILT="$ROOT/.build/release/yaz"
[ -x "$BUILT" ] || die "build output missing: $BUILT"

# --- install --------------------------------------------------------------------

printf 'installing: %s\n' "$TARGET"

if writable "$PREFIX"; then
    install -d -m 0755 "$PREFIX"
    install -m 0755 "$BUILT" "$TARGET"
else
    note "$PREFIX is not writable — asking for sudo"
    sudo install -d -m 0755 "$PREFIX"
    sudo install -m 0755 "$BUILT" "$TARGET"
fi

# Sign with the stable local certificate when one exists, so TCC grants
# survive a rebuild; fall back to ad-hoc otherwise. Neither is a distribution
# signature — that needs a Developer ID.
if command -v codesign >/dev/null 2>&1; then
    IDENTITY="$("$ROOT/scripts/signing-identity.sh" --check 2>/dev/null || true)"
    if [ -n "$IDENTITY" ]; then
        codesign --force --sign "$IDENTITY" "$TARGET" 2>/dev/null \
            && note "signed with: $IDENTITY" || note "signing failed (not fatal)"
    else
        codesign --force --sign - "$TARGET" 2>/dev/null \
            && note "ad-hoc signed — run ./scripts/signing-identity.sh for a stable identity" \
            || note "could not sign (not fatal)"
    fi
fi

# --- launch at login -------------------------------------------------------

if [ "${1:-}" = "--login" ]; then
    "$TARGET" install --launch-at-login
fi

# --- status --------------------------------------------------------------

printf '\n'
"$TARGET" doctor || true

printf '\ninstalled. next:\n'
note "yaz doctor --request     # request accessibility permission"
note "yaz models download      # pre-fetch the model (~1.6 GB)"
note "yaz                      # start the daemon"
