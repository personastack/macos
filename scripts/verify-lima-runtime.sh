#!/bin/sh
set -eu
root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
bundle=${1:?usage: verify-lima-runtime.sh APP_BUNDLE [CERTIFICATE_DER]}
certificate=${2:-"$root_dir/Resources/ReleaseSigningCertificate.der"}
python3 "$root_dir/scripts/lima_runtime.py" verify "$bundle"
launcher="$bundle/Contents/Resources/LocalCluster/lima/bin/limactl"
sh "$root_dir/scripts/verify-arm64-binaries.sh" "$launcher"
verification_dir=$(mktemp -d "${TMPDIR:-/tmp}/personastack-lima-signature.XXXXXX")
trap 'rm -rf "$verification_dir"' EXIT
requirement='identifier "ai.personastack.desktop.lima" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "5T2T8KL852"'
codesign --verify --strict -R "=$requirement" "$launcher"
codesign --display --verbose=4 "$launcher" > "$verification_dir/details" 2>&1
codesign --display --extract-certificates="$verification_dir/certificate" "$launcher" >/dev/null 2>&1
cmp "$certificate" "$verification_dir/certificate0"
grep -Fxq 'Identifier=ai.personastack.desktop.lima' "$verification_dir/details"
grep -Fxq 'TeamIdentifier=5T2T8KL852' "$verification_dir/details"
grep -Fq '(runtime)' "$verification_dir/details"
grep -q '^Timestamp=' "$verification_dir/details"
codesign --display --entitlements - --xml "$launcher" > "$verification_dir/entitlements.plist" 2>/dev/null
python3 - "$verification_dir/entitlements.plist" <<'PY'
import plistlib
import sys
with open(sys.argv[1], "rb") as source:
    if plistlib.load(source) != {"com.apple.security.virtualization": True}:
        raise SystemExit("Lima requires exactly the virtualization entitlement")
PY
