#!/bin/sh
set -eu
root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app=${1:?usage: package-desktop-installer.sh APP OUTPUT_PKG}
output=${2:?usage: package-desktop-installer.sh APP OUTPUT_PKG}
sign_installer=${PERSONASTACK_SIGN_INSTALLER:-1}
[ ! -e "$output" ] || { echo 'Refusing to replace an installer package.' >&2; exit 1; }
case "$sign_installer" in 0|1) ;; *) echo 'Invalid installer signing mode.' >&2; exit 2 ;; esac
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || exit 2
[ ! -e "$app/Contents/Resources/LockedControlInstaller.pkg" ] || {
    echo 'The app must not contain a separate locked-control installer.' >&2; exit 2;
}
if [ "$sign_installer" = 1 ]; then
    : "${PERSONASTACK_INSTALLER_SIGNING_IDENTITY:?Developer ID Installer identity is required}"
    pin=$(shasum -a 1 "$root_dir/Resources/ReleaseSigningCertificate.der" | awk '{print $1}')
    codesign --verify --strict --deep -R "=identifier \"ai.personastack.desktop\" and anchor apple generic and certificate leaf = H\"$pin\"" "$app"
fi
staging=$(mktemp -d "${TMPDIR:-/tmp}/personastack-desktop-package.XXXXXX")
trap 'rm -rf "$staging"' EXIT
mkdir -p "$staging/payload/Applications" "$staging/scripts"
pin=$(shasum -a 1 "$root_dir/Resources/ReleaseSigningCertificate.der" | awk '{print $1}')
sed "s/__CERT_SHA1__/$pin/g" "$root_dir/scripts/desktop-upgrade-preinstall.sh" > "$staging/scripts/preinstall"
chmod 755 "$staging/scripts/preinstall"
ditto "$app" "$staging/payload/Applications/PersonaStack.app"
/usr/bin/pkgbuild --analyze --root "$staging/payload" "$staging/components.plist"
# Always replace the Applications copy. Never relocate to an old app in Trash.
python3 - "$staging/components.plist" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, 'rb') as file:
    components = plistlib.load(file)
for component in components:
    component['BundleIsRelocatable'] = False
    component['BundleHasStrictIdentifier'] = True
    component['BundleOverwriteAction'] = 'upgrade'
with open(path, 'wb') as file:
    plistlib.dump(components, file)
PY
/usr/bin/pkgbuild --root "$staging/payload" --component-plist "$staging/components.plist" \
    --install-location / --ownership recommended --identifier ai.personastack.desktop \
    --version "$version" --scripts "$staging/scripts" "$staging/app.pkg"
/usr/bin/productbuild --synthesize --package "$staging/app.pkg" "$staging/distribution.xml"
python3 - "$staging/distribution.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
path = sys.argv[1]
root = ET.parse(path).getroot()
title = root.find('title')
if title is None:
    title = ET.SubElement(root, 'title')
title.text = 'PersonaStack'
options = root.find('options')
if options is None:
    options = ET.SubElement(root, 'options')
options.set('customize', 'never')
domains = ET.SubElement(root, 'domains')
domains.set('enable_anywhere', 'false')
domains.set('enable_currentUserHome', 'false')
domains.set('enable_localSystem', 'true')
volume = ET.SubElement(root, 'volume-check')
ET.SubElement(volume, 'allowed-os-versions').append(ET.Element('os-version', min='14.0'))
close = ET.SubElement(ET.SubElement(root, 'pkg-ref', id='ai.personastack.desktop'), 'must-close')
ET.SubElement(close, 'app', id='ai.personastack.desktop')
ET.ElementTree(root).write(path, encoding='utf-8', xml_declaration=True)
PY
/usr/bin/productbuild --distribution "$staging/distribution.xml" --package-path "$staging" "$staging/product.pkg"
if [ "$sign_installer" = 1 ]; then
    /usr/bin/productsign --sign "$PERSONASTACK_INSTALLER_SIGNING_IDENTITY" \
        --keychain "$PERSONASTACK_CODESIGN_KEYCHAIN" "$staging/product.pkg" "$output"
else
    # Local validation does not use release signing credentials.
    cp "$staging/product.pkg" "$output"
fi
printf '%s\n' "$output"
