#!/bin/bash
# Creates a self-signed code-signing certificate, once.
#
# Why this exists: TCC remembers Accessibility against an app's *designated requirement*.
# For an ad-hoc signature that requirement includes the binary's hash, so every rebuild
# produces a new identity and the user has to grant permission again — which turns any
# debugging session into a chore. Signing with a stable certificate keeps the requirement
# constant across rebuilds, so the grant survives.
#
# This is a local development certificate. It is not a substitute for an Apple Developer ID
# when shipping to other people.
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/appconfig.sh

CERT_NAME="${SIGNING_IDENTITY:-Touchward Local Signing}"

if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
  echo "✓ Certificate \"$CERT_NAME\" already exists — nothing to do."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "▸ Creating self-signed certificate \"$CERT_NAME\"…"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -subj "/CN=${CERT_NAME}" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  2>/dev/null

# OpenSSL 3 defaults to AES-256 PKCS12, which macOS's Keychain cannot read — the import
# fails with a misleading "wrong password" error. These force the older algorithms it
# understands.
openssl pkcs12 -export -out "$WORK/cert.p12" \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
  -passout pass:touchward 2>/dev/null

echo "▸ Importing into the login keychain…"
# -T /usr/bin/codesign lets codesign use the key without a prompt on every build.
security import "$WORK/cert.p12" \
  -k "$HOME/Library/Keychains/login.keychain-db" \
  -P "touchward" -T /usr/bin/codesign -A >/dev/null

echo "▸ Marking it trusted for code signing…"
# User trust domain: no admin password needed, and it only affects this account.
security add-trusted-cert \
  -r trustRoot -p codeSign \
  -k "$HOME/Library/Keychains/login.keychain-db" \
  "$WORK/cert.pem" 2>/dev/null || {
    echo "  ⚠️  Could not set trust automatically. Open Keychain Access → find \"$CERT_NAME\""
    echo "     → Get Info → Trust → Code Signing: Always Trust."
  }

echo
if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
  echo "✓ Done. Rebuilding will no longer cost you the permissions you granted."
  echo "  Set SIGNING_IDENTITY=\"$CERT_NAME\" in scripts/appconfig.sh"
else
  echo "✗ The certificate cannot sign yet — check the trust step above."
  exit 1
fi
