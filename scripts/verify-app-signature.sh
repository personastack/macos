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

grep -Fxq 'TeamIdentifier=5T2T8KL852' "$verification_dir/details"
grep -Fq '(runtime)' "$verification_dir/details"
grep -q '^Timestamp=' "$verification_dir/details"
expected_requirement="identifier \"$signing_id\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = \"5T2T8KL852\""
actual_requirement=$(codesign --display -r- "$bundle" 2>&1 | sed -n 's/^designated => //p')
test "$actual_requirement" = "$expected_requirement"
codesign --verify --strict -R "=$expected_requirement" "$bundle"

helper="$bundle/Contents/MacOS/PersonaStackAgentBridge"
codesign --verify --strict "$helper"
codesign --display --verbose=4 "$helper" > "$verification_dir/helper-details" 2>&1
codesign --display --extract-certificates="$verification_dir/helper-certificate" "$helper" >/dev/null 2>&1
cmp "$certificate" "$verification_dir/helper-certificate0"
grep -Fxq 'Identifier=ai.personastack.desktop.agent-bridge' "$verification_dir/helper-details"
grep -Fxq 'TeamIdentifier=5T2T8KL852' "$verification_dir/helper-details"
grep -Fq '(runtime)' "$verification_dir/helper-details"
grep -q '^Timestamp=' "$verification_dir/helper-details"
