#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
version=${VERSION:-0.1.0}
configuration=${CONFIGURATION:-release}
default_url=${PERSONASTACK_DEFAULT_URL:?Set PERSONASTACK_DEFAULT_URL to the PersonaStack environment URL for this build}
signing_identity=${PERSONASTACK_CODESIGN_IDENTITY:?Set PERSONASTACK_CODESIGN_IDENTITY to the pinned certificate-backed signing identity}
signing_keychain=${PERSONASTACK_CODESIGN_KEYCHAIN:?Set PERSONASTACK_CODESIGN_KEYCHAIN to the release signing keychain}
sparkle_public_key=${PERSONASTACK_SPARKLE_PUBLIC_ED_KEY:-}
artifact_dir="$root_dir/artifacts"
bundle_dir="$root_dir/build/PersonaStack.app"
staging_dir="$root_dir/build/dmg-root"
rw_dmg="$root_dir/build/PersonaStack-$version-rw.dmg"
arm64_build_dir="$root_dir/build/swift-arm64"
x86_64_build_dir="$root_dir/build/swift-x86_64"

case "$configuration" in
  release) product_configuration=Release ;;
  debug) product_configuration=Debug ;;
  *) printf '%s\n' "Unsupported configuration: $configuration" >&2; exit 2 ;;
esac

if ! printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  printf '%s\n' "Stable release version must use numeric major.minor.patch: $version" >&2
  exit 2
fi
if [ "$signing_identity" = '-' ]; then
  printf '%s\n' 'Ad-hoc signatures cannot preserve macOS permission identity across updates.' >&2
  exit 2
fi
if [ -n "$sparkle_public_key" ] && ! printf '%s' "$sparkle_public_key" | grep -Eq '^[A-Za-z0-9+/]+={0,2}$'; then
  printf '%s\n' 'PERSONASTACK_SPARKLE_PUBLIC_ED_KEY must be base64.' >&2
  exit 2
fi
if [ -n "$sparkle_public_key" ] && ! python3 -c 'import base64,sys; assert len(base64.b64decode(sys.argv[1], validate=True)) == 32' "$sparkle_public_key" 2>/dev/null; then
  printf '%s\n' 'PERSONASTACK_SPARKLE_PUBLIC_ED_KEY must decode to a 32-byte Ed25519 public key.' >&2
  exit 2
fi

"$root_dir/scripts/build-icon.sh"
swift run --package-path "$root_dir" PersonaStackPolicyCheck
if [ "${CLEAN_BUILD:-1}" = 1 ]; then
  rm -rf "$arm64_build_dir" "$x86_64_build_dir"
fi
swift build --package-path "$root_dir" --scratch-path "$arm64_build_dir" --triple arm64-apple-macosx14.0 -c "$configuration"
swift build --package-path "$root_dir" --scratch-path "$x86_64_build_dir" --triple x86_64-apple-macosx14.0 -c "$configuration"
arm64_binary=$(find "$arm64_build_dir" -type f -name PersonaStack -perm -111 -print -quit)
x86_64_binary=$(find "$x86_64_build_dir" -type f -name PersonaStack -perm -111 -print -quit)
test -n "$arm64_binary"
test -n "$x86_64_binary"

rm -rf "$bundle_dir" "$staging_dir" "$rw_dmg"
mkdir -p "$bundle_dir/Contents/MacOS" "$bundle_dir/Contents/Resources" "$bundle_dir/Contents/Frameworks" \
  "$bundle_dir/Contents/Library/LaunchAgents" "$staging_dir"
lipo -create \
  "$arm64_binary" \
  "$x86_64_binary" \
  -output "$bundle_dir/Contents/MacOS/PersonaStack"
lipo -create \
  "$(dirname "$arm64_binary")/PersonaStackHarnessHook" \
  "$(dirname "$x86_64_binary")/PersonaStackHarnessHook" \
  -output "$bundle_dir/Contents/MacOS/PersonaStackHarnessHook"
chmod 755 "$bundle_dir/Contents/MacOS/PersonaStackHarnessHook"
if [ "$configuration" = release ]; then
  : "${PERSONASTACK_INSTALLER_SIGNING_IDENTITY:?Developer ID Installer identity is required for the main installer}"
fi
cp "$root_dir/Resources/Info.plist" "$bundle_dir/Contents/Info.plist"
cp "$root_dir/Resources/AppIcon.icns" "$bundle_dir/Contents/Resources/AppIcon.icns"
cp "$root_dir/Resources/MenuBarIcon.png" "$bundle_dir/Contents/Resources/MenuBarIcon.png"
cp "$root_dir/Resources/ReleaseSigningCertificate.der" "$bundle_dir/Contents/Resources/ReleaseSigningCertificate.der"
ditto "$(dirname "$arm64_binary")/PersonaStackDesktop_PersonaStackCore.bundle" \
  "$bundle_dir/Contents/Resources/PersonaStackDesktop_PersonaStackCore.bundle"
cp "$root_dir/Resources/LaunchAgents/ai.personastack.desktop.crash-recovery.plist" \
  "$bundle_dir/Contents/Library/LaunchAgents/ai.personastack.desktop.crash-recovery.plist"
cp "$root_dir/.build/checkouts/Sparkle/LICENSE" "$bundle_dir/Contents/Resources/Sparkle-LICENSE.txt"
sparkle_framework="$root_dir/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ ! -d "$sparkle_framework" ]; then
  printf '%s\n' 'Sparkle framework artifact is missing. Run swift package resolve first.' >&2
  exit 1
fi
ditto "$sparkle_framework" "$bundle_dir/Contents/Frameworks/Sparkle.framework"
chmod 755 "$bundle_dir/Contents/MacOS/PersonaStack"
plutil -replace CFBundleShortVersionString -string "$version" "$bundle_dir/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$version" "$bundle_dir/Contents/Info.plist"
plutil -replace PersonaStackDefaultURL -string "$default_url" "$bundle_dir/Contents/Info.plist"
if [ -n "$sparkle_public_key" ]; then
  /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $sparkle_public_key" "$bundle_dir/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $sparkle_public_key" "$bundle_dir/Contents/Info.plist"
fi

artifact_suffix=developerid
"$root_dir/scripts/sign-app.sh" "$bundle_dir"
"$root_dir/scripts/verify-update-bundle.sh" "$bundle_dir" "$version" "$sparkle_public_key"
"$root_dir/scripts/notarize.sh" "$bundle_dir"
spctl --assess --type execute --verbose=2 "$bundle_dir"

PERSONASTACK_SIGN_INSTALLER=1 "$root_dir/scripts/package-desktop-installer.sh" "$bundle_dir" \
  "$staging_dir/Install PersonaStack.pkg"
"$root_dir/scripts/notarize.sh" "$staging_dir/Install PersonaStack.pkg"
spctl --assess --type install --verbose=2 "$staging_dir/Install PersonaStack.pkg"
mkdir -p "$staging_dir/.background"
"$root_dir/scripts/render-dmg-background.swift" "$staging_dir/.background/background@2x.png"
mkdir -p "$artifact_dir"
hdiutil create -volname "PersonaStack" -srcfolder "$staging_dir" -ov -format UDRW "$rw_dmg" >/dev/null
mount_root=$(mktemp -d "${TMPDIR:-/tmp}/personastack-dmg.XXXXXX")
mount_point="$mount_root/mount"
mkdir "$mount_point"
cleanup_mount() {
  hdiutil detach "$mount_point" >/dev/null 2>&1 || true
  rmdir "$mount_point" "$mount_root" 2>/dev/null || true
}
trap cleanup_mount EXIT
hdiutil attach -readwrite -noverify -noautoopen -mountpoint "$mount_point" "$rw_dmg" >/dev/null
osascript - "$mount_point" <<'APPLESCRIPT'
on run argv
tell application "Finder"
  tell folder (POSIX file (item 1 of argv) as alias)
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {120, 100, 860, 600}
    set icon size of icon view options of container window to 112
    set text size of icon view options of container window to 12
    set label position of icon view options of container window to bottom
    set shows item info of icon view options of container window to false
    set arrangement of icon view options of container window to not arranged
    set background picture of icon view options of container window to file ".background:background@2x.png"
    set position of item "Install PersonaStack.pkg" of container window to {370, 260}
    update without registering applications
    delay 2
    close
    delay 2
  end tell
end tell
end run
APPLESCRIPT
hdiutil detach "$mount_point" >/dev/null
rmdir "$mount_point" "$mount_root"
trap - EXIT
hdiutil convert "$rw_dmg" -ov -format UDZO -imagekey zlib-level=9 -o "$artifact_dir/PersonaStack-$version-$artifact_suffix.dmg" >/dev/null
rm -f "$rw_dmg"
codesign --force --timestamp --keychain "$signing_keychain" --sign "$signing_identity" \
  "$artifact_dir/PersonaStack-$version-$artifact_suffix.dmg"
"$root_dir/scripts/notarize.sh" "$artifact_dir/PersonaStack-$version-$artifact_suffix.dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 \
  "$artifact_dir/PersonaStack-$version-$artifact_suffix.dmg"
printf '%s\n' "$artifact_dir/PersonaStack-$version-$artifact_suffix.dmg"
