#!/bin/sh
set -eu
umask 077

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"
: "${PERSONASTACK_CODESIGN_CERTIFICATE_P12_BASE64:?release signing certificate is required}"
: "${PERSONASTACK_CODESIGN_CERTIFICATE_PASSWORD:?release signing certificate password is required}"
certificate="$root_dir/Resources/ReleaseSigningCertificate.der"
identity_dir="$RUNNER_TEMP/personastack-release-signing"
mkdir -p "$identity_dir"
printf '%s' "$PERSONASTACK_CODESIGN_CERTIFICATE_P12_BASE64" | openssl base64 -d -A > "$identity_dir/identity.p12"
openssl pkcs12 -in "$identity_dir/identity.p12" -clcerts -nokeys \
  -passin env:PERSONASTACK_CODESIGN_CERTIFICATE_PASSWORD | \
  openssl x509 -outform DER > "$identity_dir/imported-certificate.der"
cmp "$certificate" "$identity_dir/imported-certificate.der"
keychain="$identity_dir/signing.keychain-db"
security create-keychain -p "$PERSONASTACK_CODESIGN_CERTIFICATE_PASSWORD" "$keychain"
security set-keychain-settings -lut 7200 "$keychain"
security unlock-keychain -p "$PERSONASTACK_CODESIGN_CERTIFICATE_PASSWORD" "$keychain"
security import "$identity_dir/identity.p12" -k "$keychain" \
  -P "$PERSONASTACK_CODESIGN_CERTIFICATE_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
  -k "$PERSONASTACK_CODESIGN_CERTIFICATE_PASSWORD" "$keychain" >/dev/null
identity=$(openssl x509 -inform DER -in "$certificate" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')
printf 'PERSONASTACK_CODESIGN_IDENTITY=%s\nPERSONASTACK_CODESIGN_KEYCHAIN=%s\n' "$identity" "$keychain" >> "$GITHUB_ENV"
