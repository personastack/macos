#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
version=${VERSION:-0.1.0}
configuration=${CONFIGURATION:-release}
default_url=${PERSONASTACK_DEFAULT_URL:?Set PERSONASTACK_DEFAULT_URL to the PersonaStack environment URL for this build}
signing_identity=${PERSONASTACK_CODESIGN_IDENTITY:-}
artifact_dir="$root_dir/artifacts"
bundle_dir="$root_dir/build/PersonaStack.app"
staging_dir="$root_dir/build/dmg-root"
rw_dmg="$root_dir/build/PersonaStack-$version-rw.dmg"
arm64_build_dir="$root_dir/build/swift-arm64"
x86_64_build_dir="$root_dir/build/swift-x86_64"
mount_point="/Volumes/PersonaStack"

case "$configuration" in
  release) product_configuration=Release ;;
  debug) product_configuration=Debug ;;
  *) printf '%s\n' "Unsupported configuration: $configuration" >&2; exit 2 ;;
esac

"$root_dir/scripts/build-icon.sh"
swift run --package-path "$root_dir" PersonaStackPolicyCheck
rm -rf "$arm64_build_dir" "$x86_64_build_dir"
swift build --package-path "$root_dir" --scratch-path "$arm64_build_dir" --triple arm64-apple-macosx14.0 -c "$configuration"
swift build --package-path "$root_dir" --scratch-path "$x86_64_build_dir" --triple x86_64-apple-macosx14.0 -c "$configuration"
arm64_binary=$(find "$arm64_build_dir" -type f -name PersonaStack -perm -111 -print -quit)
x86_64_binary=$(find "$x86_64_build_dir" -type f -name PersonaStack -perm -111 -print -quit)
test -n "$arm64_binary"
test -n "$x86_64_binary"

rm -rf "$bundle_dir" "$staging_dir" "$rw_dmg"
mkdir -p "$bundle_dir/Contents/MacOS" "$bundle_dir/Contents/Resources" "$staging_dir"
lipo -create \
  "$arm64_binary" \
  "$x86_64_binary" \
  -output "$bundle_dir/Contents/MacOS/PersonaStack"
cp "$root_dir/Resources/Info.plist" "$bundle_dir/Contents/Info.plist"
cp "$root_dir/Resources/AppIcon.icns" "$bundle_dir/Contents/Resources/AppIcon.icns"
chmod 755 "$bundle_dir/Contents/MacOS/PersonaStack"
plutil -replace CFBundleShortVersionString -string "$version" "$bundle_dir/Contents/Info.plist"
plutil -replace PersonaStackDefaultURL -string "$default_url" "$bundle_dir/Contents/Info.plist"

artifact_suffix=unsigned
if [ -n "$signing_identity" ]; then
  if [ "$signing_identity" = "-" ]; then
    artifact_suffix=adhoc
    codesign --force --options runtime --identifier ai.personastack.desktop --sign "$signing_identity" "$bundle_dir"
  else
    artifact_suffix=signed
    codesign --force --options runtime --timestamp --identifier ai.personastack.desktop --sign "$signing_identity" "$bundle_dir"
  fi
  codesign --verify --deep --strict --verbose=2 "$bundle_dir"
fi

cp -R "$bundle_dir" "$staging_dir/"
mkdir -p "$staging_dir/.background"
"$root_dir/scripts/render-dmg-background.swift" "$staging_dir/.background/background@2x.png"
ln -s /Applications "$staging_dir/Applications"
mkdir -p "$artifact_dir"
if [ -e "$mount_point" ]; then
  printf '%s\n' "Eject the existing PersonaStack volume before packaging" >&2
  exit 1
fi
hdiutil create -volname "PersonaStack" -srcfolder "$staging_dir" -ov -format UDRW "$rw_dmg" >/dev/null
hdiutil attach -readwrite -noverify -noautoopen "$rw_dmg" >/dev/null
trap 'hdiutil detach "$mount_point" >/dev/null 2>&1 || true' EXIT
osascript <<'APPLESCRIPT'
tell application "Finder"
  tell disk "PersonaStack"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {120, 100, 860, 600}
    set icon size of icon view options of container window to 112
    set arrangement of icon view options of container window to not arranged
    set background picture of icon view options of container window to file ".background:background@2x.png"
    set position of item "PersonaStack.app" of container window to {180, 260}
    set position of item "Applications" of container window to {560, 260}
    update without registering applications
    delay 2
    close
    delay 2
  end tell
end tell
APPLESCRIPT
hdiutil detach "$mount_point" >/dev/null
trap - EXIT
hdiutil convert "$rw_dmg" -ov -format UDZO -imagekey zlib-level=9 -o "$artifact_dir/PersonaStack-$version-$artifact_suffix.dmg" >/dev/null
rm -f "$rw_dmg"
printf '%s\n' "$artifact_dir/PersonaStack-$version-$artifact_suffix.dmg"
