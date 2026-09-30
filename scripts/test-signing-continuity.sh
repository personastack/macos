#!/bin/sh
set -eu
umask 077

# Use the macOS OpenSSL implementation for PKCS12 compatibility with Security.framework.
openssl_bin=/usr/bin/openssl

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
: "${PERSONASTACK_CODESIGN_IDENTITY:?certificate signing identity is required}"
: "${PERSONASTACK_CODESIGN_KEYCHAIN:?signing keychain is required}"
fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/personastack-signing-test.XXXXXX")
cleanup() {
  if [ -f "$fixture_dir/foreign.keychain-db" ]; then
    security delete-keychain "$fixture_dir/foreign.keychain-db"
  fi
  rm -rf "$fixture_dir"
}
trap cleanup EXIT

make_bundle() {
  fixture_bundle="$fixture_dir/$1.app"
  mkdir -p "$fixture_bundle/Contents/MacOS" "$fixture_bundle/Contents/Resources"
  cp "$2" "$fixture_bundle/Contents/MacOS/PersonaStack"
  printf '%s\n' "$1" > "$fixture_bundle/Contents/Resources/probe.txt"
  cat > "$fixture_bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>ai.personastack.desktop</string>
<key>CFBundleExecutable</key><string>PersonaStack</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>$3</string>
</dict></plist>
PLIST
}

make_bundle first /usr/bin/true 1.0.0
make_bundle second /usr/bin/false 1.0.1
for name in first second; do
  codesign --force --timestamp=none --identifier ai.personastack.desktop \
    --keychain "$PERSONASTACK_CODESIGN_KEYCHAIN" --sign "$PERSONASTACK_CODESIGN_IDENTITY" "$fixture_dir/$name.app"
  "$root_dir/scripts/verify-app-signature.sh" "$fixture_dir/$name.app"
  codesign --display -r- "$fixture_dir/$name.app" 2>&1 | sed -n 's/^designated => //p' > "$fixture_dir/$name.requirement"
done
cmp "$fixture_dir/first.requirement" "$fixture_dir/second.requirement"
codesign --verify --strict -R "=$(cat "$fixture_dir/first.requirement")" "$fixture_dir/second.app"
codesign --verify --strict -R "=$(cat "$fixture_dir/second.requirement")" "$fixture_dir/first.app"

# A different certificate cannot impersonate this app by reusing its identifier.
cat > "$fixture_dir/certificate.cnf" <<'CONFIG'
[req]
distinguished_name = subject
x509_extensions = signing
prompt = no
[subject]
CN = PersonaStack Negative Signing Fixture
[signing]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
CONFIG
fixture_password=$("$openssl_bin" rand -hex 32)
export PERSONASTACK_SIGNING_FIXTURE_PASSWORD="$fixture_password"
"$openssl_bin" req -new -newkey rsa:2048 -nodes -x509 -days 1 -sha256 \
  -config "$fixture_dir/certificate.cnf" -keyout "$fixture_dir/key.pem" -out "$fixture_dir/certificate.pem" >/dev/null 2>&1
"$openssl_bin" pkcs12 -export -inkey "$fixture_dir/key.pem" -in "$fixture_dir/certificate.pem" \
  -out "$fixture_dir/foreign.p12" -passout env:PERSONASTACK_SIGNING_FIXTURE_PASSWORD
security create-keychain -p "$fixture_password" "$fixture_dir/foreign.keychain-db"
security unlock-keychain -p "$fixture_password" "$fixture_dir/foreign.keychain-db"
security import "$fixture_dir/foreign.p12" -k "$fixture_dir/foreign.keychain-db" -P "$fixture_password" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$fixture_password" "$fixture_dir/foreign.keychain-db" >/dev/null
# codesign also searches the user keychain list when constructing the certificate chain.
# Preserve existing entries. Deleting this temporary keychain removes only its entry.
python3 - "$fixture_dir/foreign.keychain-db" <<'PYTHON'
import shlex
import subprocess
import sys

keychains = shlex.split(subprocess.check_output(["security", "list-keychains", "-d", "user"], text=True))
if sys.argv[1] not in keychains:
    subprocess.run(["security", "list-keychains", "-d", "user", "-s", *keychains, sys.argv[1]], check=True)
PYTHON
foreign_identity=$("$openssl_bin" x509 -in "$fixture_dir/certificate.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')
make_bundle foreign /usr/bin/true 1.0.2
codesign --force --timestamp=none --identifier ai.personastack.desktop \
  --keychain "$fixture_dir/foreign.keychain-db" --sign "$foreign_identity" "$fixture_dir/foreign.app"
if codesign --verify --strict -R "=$(cat "$fixture_dir/first.requirement")" "$fixture_dir/foreign.app" >/dev/null 2>&1; then
  printf '%s\n' 'A foreign signer passed the release identity requirement.' >&2; exit 1
fi
if "$root_dir/scripts/verify-app-signature.sh" "$fixture_dir/foreign.app" >/dev/null 2>&1; then
  printf '%s\n' 'Bundle validation accepted a foreign signer.' >&2; exit 1
fi
cp -R "$fixture_dir/first.app" "$fixture_dir/adhoc.app"
codesign --force --sign - "$fixture_dir/adhoc.app" >/dev/null 2>&1
if "$root_dir/scripts/verify-app-signature.sh" "$fixture_dir/adhoc.app" >/dev/null 2>&1; then
  printf '%s\n' 'Bundle validation accepted an ad-hoc signer.' >&2; exit 1
fi
printf '%s\n' tampered > "$fixture_dir/second.app/Contents/Resources/probe.txt"
if "$root_dir/scripts/verify-app-signature.sh" "$fixture_dir/second.app" >/dev/null 2>&1; then
  printf '%s\n' 'Bundle validation accepted changed sealed resources.' >&2; exit 1
fi
printf '%s\n' 'Signing continuity, foreign-signer rejection, ad-hoc rejection, and resource seals passed.'
