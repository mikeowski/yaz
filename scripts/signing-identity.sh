#!/bin/sh
# Creates (once) a self-signed code-signing certificate for yaz.
#
# Why this exists: macOS keys a TCC grant to the *code signing identity*. An
# ad-hoc signature has no identity beyond the binary's own hash, so every
# rebuild produces a different one — and the Accessibility permission you
# granted yesterday silently stops applying today. That is exactly the symptom
# "I gave it permission and it still asks".
#
# A self-signed certificate gives the app a stable identity: the same
# certificate signs every build, so the grant survives rebuilds. It is not a
# Developer ID — Gatekeeper still treats the app as unidentified on other
# machines — but for a locally built app it is the difference between granting
# permission once and granting it every time.
#
#   ./scripts/signing-identity.sh          # create if missing, print the name
#   ./scripts/signing-identity.sh --check  # print the name if it exists, else nothing

set -eu

CERT_NAME="yaz Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

exists() {
    security find-identity -v -p codesigning 2>/dev/null | grep -qF "$CERT_NAME"
}

if [ "${1:-}" = "--check" ]; then
    exists && printf '%s\n' "$CERT_NAME"
    exit 0
fi

if exists; then
    printf '%s\n' "$CERT_NAME"
    exit 0
fi

printf 'creating a local signing certificate: %s\n' "$CERT_NAME" >&2

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A self-signed cert with the codeSigning extended key usage. `codesign`
# refuses anything without it.
cat > "$TMP/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no

[ dn ]
CN = $CERT_NAME

[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/openssl.cnf" 2>/dev/null \
    || { printf '✗ openssl failed\n' >&2; exit 1; }

# -legacy and a real password, both required: OpenSSL 3 defaults to a PKCS12
# MAC that macOS Security cannot verify, and an empty password fails the same
# check. Together they produce "MAC verification failed during PKCS12 import".
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/bundle.p12" -passout pass:yaz 2>/dev/null \
    || { printf '✗ pkcs12 export failed\n' >&2; exit 1; }

# -T codesign lets codesign use the key without prompting for the keychain
# password on every single build.
security import "$TMP/bundle.p12" -k "$KEYCHAIN" -P yaz \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null 2>&1 \
    || { printf '✗ keychain import failed\n' >&2; exit 1; }

# Trust the certificate for code signing. This is the step that may ask for
# your login password — once.
printf '  macOS will ask for your login password to trust the certificate\n' >&2
security add-trusted-cert -d -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" \
    >/dev/null 2>&1 || printf '  (could not mark it trusted — signing may still work)\n' >&2

# Allow codesign to use the key non-interactively from now on.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" \
    >/dev/null 2>&1 || true

if exists; then
    printf '✓ %s created\n' "$CERT_NAME" >&2
    printf '%s\n' "$CERT_NAME"
else
    printf '✗ certificate was not registered for code signing\n' >&2
    exit 1
fi
