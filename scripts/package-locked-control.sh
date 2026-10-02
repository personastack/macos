#!/bin/sh
set -eu
root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tool=${1:?usage: package-locked-control.sh COMPILED_INSTALLER OUTPUT_PKG}
output=${2:?usage: package-locked-control.sh COMPILED_INSTALLER OUTPUT_PKG}
: "${PERSONASTACK_CODESIGN_IDENTITY:?Developer ID Application identity is required}"
: "${PERSONASTACK_CODESIGN_KEYCHAIN:?signing keychain is required}"
[ ! -e "$output" ] || { echo 'Refusing to replace an installer package.' >&2; exit 1; }
staging=$(mktemp -d "${TMPDIR:-/tmp}/personastack-locked-package.XXXXXX")
trap 'rm -rf "$staging"' EXIT
sh "$root_dir/Experiments/LockedSessionCandidate/build.sh" "$staging/candidate"
payload="$staging/payload"
plugin_parent="$payload/Library/Security/SecurityAgentPlugins"
helper_parent="$payload/Library/Application Support/PersonaStack"
mkdir -p "$plugin_parent" "$helper_parent"
ditto "$staging/candidate/PersonaStackLockedGrantCandidate.bundle" "$plugin_parent/PersonaStackLockedGrantCandidate.bundle"
cp "$tool" "$helper_parent/LockedControlInstaller"
chmod 755 "$helper_parent/LockedControlInstaller"
codesign --force --timestamp --options runtime --keychain "$PERSONASTACK_CODESIGN_KEYCHAIN" \
    --sign "$PERSONASTACK_CODESIGN_IDENTITY" "$plugin_parent/PersonaStackLockedGrantCandidate.bundle"
codesign --force --timestamp --options runtime --keychain "$PERSONASTACK_CODESIGN_KEYCHAIN" \
    --identifier ai.personastack.locked-control-installer --sign "$PERSONASTACK_CODESIGN_IDENTITY" \
    "$helper_parent/LockedControlInstaller"
pin=$(shasum -a 1 "$root_dir/Resources/ReleaseSigningCertificate.der" | awk '{print $1}')
codesign --verify --strict --deep -R "=identifier \"ai.personastack.locked-grant-candidate\" and anchor apple generic and certificate leaf = H\"$pin\"" \
    "$plugin_parent/PersonaStackLockedGrantCandidate.bundle"
codesign --verify --strict -R "=identifier \"ai.personastack.locked-control-installer\" and anchor apple generic and certificate leaf = H\"$pin\"" \
    "$helper_parent/LockedControlInstaller"
# The enclosing signed app seals the embedded package. Public distribution also
# requires a Developer ID Installer signature and normal notarization gates.
/usr/bin/pkgbuild --root "$payload" --install-location / --ownership recommended \
    --identifier ai.personastack.locked-control --version 1 \
    --scripts "$root_dir/Resources/LockedControlInstaller" "$staging/component.pkg"
if [ -n "${PERSONASTACK_INSTALLER_SIGNING_IDENTITY:-}" ]; then
    /usr/bin/productsign --sign "$PERSONASTACK_INSTALLER_SIGNING_IDENTITY" \
        --keychain "$PERSONASTACK_CODESIGN_KEYCHAIN" "$staging/component.pkg" "$output"
else
    cp "$staging/component.pkg" "$output"
fi
printf '%s\n' "$output"
