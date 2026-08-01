#!/bin/sh
# yaz.app paketini ve dağıtım için DMG'yi üretir.
#
#   ./scripts/bundle.sh          # dist/yaz.app
#   ./scripts/bundle.sh --dmg    # ayrıca dist/yaz-<sürüm>.dmg
#
# Neden .app: macOS erişilebilirlik iznini "sorumlu sürece" atfeder. Terminalden
# çalıştırılan bir CLI'da bu terminaldir — gözlenen zincir:
#     cmux.app → login → fish → claude → zsh → yaz
# İzin penceresi cmux.app diye sorar, verilen izin zaten çalışan kabuklara
# işlemez ve bu CLI'nın içinden düzeltilemez. .app olarak yaz'ın kendi kimliği
# olur: pencere "yaz" der ve izin hangi terminalin açık olduğundan bağımsız kalır.

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/yaz.app"

die() { printf '✗ %s\n' "$*" >&2; exit 1; }
note() { printf '  %s\n' "$*"; }

[ "$(uname -s)" = "Darwin" ] || die "yalnızca macOS"
[ "$(uname -m)" = "arm64" ] || die "Apple Silicon gerekiyor"
command -v swift >/dev/null 2>&1 || die "swift bulunamadı"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$ROOT/Resources/AppInfo.plist" 2>/dev/null || echo 0.1.0)"

# --- derle ------------------------------------------------------------------

printf 'derleniyor…\n'
cd "$ROOT"
swift build -c release
BUILT="$ROOT/.build/release/yaz"
[ -x "$BUILT" ] || die "derleme çıktısı yok: $BUILT"

# --- paketle ----------------------------------------------------------------

printf 'paketleniyor: %s\n' "$APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BUILT" "$APP/Contents/MacOS/yaz"
cp "$ROOT/Resources/AppInfo.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# İkili kendi __TEXT,__info_plist bölümünü de taşıyor (CLI olarak
# çalıştırıldığında gereken kimlik). Bir paket içinde Contents/Info.plist
# önceliklidir; ikisi de aynı bundle kimliğini taşıyor, bu yüzden çelişmiyorlar.

# --- imzala -----------------------------------------------------------------
#
# Ad-hoc imza. Dağıtım imzası DEĞİL: yeniden derlendiğinde cdhash değişir ve
# TCC izinleri sıfırlanabilir. Kalıcı çözüm Developer ID + noterleme.
if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - --options runtime "$APP" 2>/dev/null \
        || codesign --force --deep --sign - "$APP" 2>/dev/null \
        || note "imzalanamadı (sorun değil)"
    codesign -dv "$APP" 2>&1 | grep -E '^(Identifier|Signature)' | sed 's/^/  /' || true
fi

# Paket gerçekten açılıyor mu.
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" >/dev/null \
    || die "Info.plist okunamıyor"
"$APP/Contents/MacOS/yaz" --help >/dev/null 2>&1 || die "paketlenen ikili çalışmıyor"

printf '✓ %s (sürüm %s)\n' "$APP" "$VERSION"

# --- dmg --------------------------------------------------------------------

if [ "${1:-}" = "--dmg" ]; then
    DMG="$DIST/yaz-$VERSION.dmg"
    STAGE="$(mktemp -d)"
    printf 'DMG hazırlanıyor…\n'

    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    cp "$ROOT/README.md" "$STAGE/OKUBENI.md" 2>/dev/null || true

    rm -f "$DMG"
    hdiutil create -volname "yaz" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG" \
        || die "hdiutil başarısız"
    rm -rf "$STAGE"

    printf '✓ %s (%s)\n' "$DMG" "$(du -h "$DMG" | cut -f1)"
    note "kurulum: DMG'yi aç, yaz.app'i Applications'a sürükle"
    note "imzasız olduğu için ilk açılışta sağ tık → Aç gerekebilir"
fi
