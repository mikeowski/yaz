#!/bin/sh
# yaz kurulum betiği — kaynaktan derler, /usr/local/bin altına kurar.
#
# Bilerek `curl | sh` değil. Bu betik sudo istiyor ve TCC izinleri talep eden
# bir daemon kuruyor; okumadan çalıştırılmamalı.
#
#   ./scripts/install.sh              # derle + kur
#   ./scripts/install.sh --login      # ayrıca girişte başlatmayı aç
#   ./scripts/install.sh --uninstall  # ikiliyi ve girişte başlatmayı kaldır

set -eu

PREFIX="${PREFIX:-/usr/local/bin}"
TARGET="$PREFIX/yaz"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

die() { printf '✗ %s\n' "$*" >&2; exit 1; }
note() { printf '  %s\n' "$*"; }

# sudo yalnızca gerçekten gerekliyse. Bir dizin henüz yoksa karar onun değil,
# ebeveyninin yazılabilirliğine bağlı — aksi halde ~/bin gibi bir hedefe kurmak
# da parola soruyordu.
writable() {
    if [ -d "$1" ]; then [ -w "$1" ]; else [ -w "$(dirname "$1")" ]; fi
}

# --- ön koşullar -------------------------------------------------------------

[ "$(uname -s)" = "Darwin" ] || die "yaz yalnızca macOS'ta çalışır"

# Whisper ve Parakeet Apple Neural Engine üzerinde çalışıyor; Intel'de model
# yüklense bile kullanılabilir gecikme alınamaz.
[ "$(uname -m)" = "arm64" ] || die "Apple Silicon gerekiyor (Intel desteklenmiyor)"

os_major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$os_major" -ge 26 ] || die "macOS 26 veya üstü gerekiyor (bulunan: $(sw_vers -productVersion))"

command -v swift >/dev/null 2>&1 || die "swift bulunamadı — Xcode veya Command Line Tools kur"

# --- kaldırma ---------------------------------------------------------------

if [ "${1:-}" = "--uninstall" ]; then
    if [ -x "$TARGET" ]; then
        "$TARGET" install --uninstall 2>/dev/null || true
    fi
    if [ -e "$TARGET" ]; then
        printf 'kaldırılıyor: %s\n' "$TARGET"
        if writable "$PREFIX"; then
            rm -f "$TARGET"
        else
            note "$PREFIX için yazma izni yok — sudo isteniyor"
            sudo rm -f "$TARGET"
        fi
    fi
    printf '✓ yaz kaldırıldı\n'
    note "modeller ~/Documents/huggingface altında duruyor — istersen elle sil"
    note "ayarlar ~/.config/yaz/config.json altında duruyor"
    exit 0
fi

# --- derle ------------------------------------------------------------------

printf 'derleniyor…\n'
cd "$ROOT"
swift build -c release

BUILT="$ROOT/.build/release/yaz"
[ -x "$BUILT" ] || die "derleme çıktısı bulunamadı: $BUILT"

# --- kur --------------------------------------------------------------------

printf 'kuruluyor: %s\n' "$TARGET"

if writable "$PREFIX"; then
    install -d -m 0755 "$PREFIX"
    install -m 0755 "$BUILT" "$TARGET"
else
    note "$PREFIX için yazma izni yok — sudo isteniyor"
    sudo install -d -m 0755 "$PREFIX"
    sudo install -m 0755 "$BUILT" "$TARGET"
fi

# Ad-hoc imza. Bu bir dağıtım imzası değil; imzasız bir ikilinin her
# derlemede TCC kimliğini kaybetmesini bir nebze yavaşlatır. Gerçek çözüm
# Developer ID ile imzalamak.
if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$TARGET" 2>/dev/null \
        && note "ad-hoc imzalandı" \
        || note "ad-hoc imzalanamadı (sorun değil)"
fi

# --- girişte başlatma -------------------------------------------------------

if [ "${1:-}" = "--login" ]; then
    "$TARGET" install --launch-at-login
fi

# --- son durum --------------------------------------------------------------

printf '\n'
"$TARGET" doctor || true

printf '\nkurulum tamam. sırada:\n'
note "yaz doctor --request     # erişilebilirlik iznini iste"
note "yaz models download      # modeli önden indir (~1.6 GB)"
note "yaz                      # daemon'ı başlat"
