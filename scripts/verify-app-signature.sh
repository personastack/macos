#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
bundle=${1:?usage: verify-app-signature.sh APP_BUNDLE [CERTIFICATE_DER]}
certificate=${2:-"$root_dir/Resources/ReleaseSigningCertificate.der"}
signing_id=ai.personastack.desktop
verification_dir=$(mktemp -d "${TMPDIR:-/tmp}/personastack-signature.XXXXXX")
trap 'rm -rf "$verification_dir"' EXIT

codesign --verify --deep --strict "$bundle"
codesign --display --verbose=4 "$bundle" > "$verification_dir/details" 2>&1
codesign --display --extract-certificates="$verification_dir/certificate" "$bundle" >/dev/null 2>&1
cmp "$certificate" "$verification_dir/certificate0"
grep -Fxq "Identifier=$signing_id" "$verification_dir/details"
grep -Eq '^Info.plist entries=[1-9][0-9]*' "$verification_dir/details"
test -s "$bundle/Contents/_CodeSignature/CodeResources"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist")" = "$signing_id"

certificate_hash=$(openssl x509 -inform DER -in "$certificate" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]')
expected_requirement="identifier \"$signing_id\" and certificate leaf = H\"$certificate_hash\""
actual_requirement=$(codesign --display -r- "$bundle" 2>&1 | sed -n 's/^designated => //p')
test "$actual_requirement" = "$expected_requirement"
codesign --verify --strict -R "=$expected_requirement" "$bundle"
