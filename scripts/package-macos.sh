#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
version=${VERSION:-0.1.0}
configuration=${CONFIGURATION:-release}
default_url=${PERSONASTACK_DEFAULT_URL:-https://my.personastack.ai/user/personas}
artifact_dir="$root_dir/artifacts"
bundle_dir="$root_dir/build/PersonaStack.app"
staging_dir="$root_dir/build/dmg-root"
arm64_build_dir="$root_dir/build/swift-arm64"
x86_64_build_dir="$root_dir/build/swift-x86_64"

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
arm64_helper=$(find "$arm64_build_dir" -type f -name PersonaStackLocalSession -perm -111 -print -quit)
x86_64_helper=$(find "$x86_64_build_dir" -type f -name PersonaStackLocalSession -perm -111 -print -quit)
test -n "$arm64_helper"
test -n "$x86_64_helper"

rm -rf "$bundle_dir" "$staging_dir"
mkdir -p "$bundle_dir/Contents/MacOS" "$bundle_dir/Contents/Resources" "$staging_dir"
lipo -create \
  "$arm64_binary" \
  "$x86_64_binary" \
  -output "$bundle_dir/Contents/MacOS/PersonaStack"
lipo -create "$arm64_helper" "$x86_64_helper" -output "$bundle_dir/Contents/MacOS/PersonaStackLocalSession"
cp "$root_dir/Resources/Info.plist" "$bundle_dir/Contents/Info.plist"
cp "$root_dir/Resources/AppIcon.icns" "$bundle_dir/Contents/Resources/AppIcon.icns"
chmod 755 "$bundle_dir/Contents/MacOS/PersonaStack"
chmod 755 "$bundle_dir/Contents/MacOS/PersonaStackLocalSession"
plutil -replace CFBundleShortVersionString -string "$version" "$bundle_dir/Contents/Info.plist"
plutil -replace PersonaStackDefaultURL -string "$default_url" "$bundle_dir/Contents/Info.plist"

cp -R "$bundle_dir" "$staging_dir/"
mkdir -p "$artifact_dir"
hdiutil create -volname "PersonaStack" -srcfolder "$staging_dir" -ov -format UDZO "$artifact_dir/PersonaStack-$version-unsigned.dmg" >/dev/null
printf '%s\n' "$artifact_dir/PersonaStack-$version-unsigned.dmg"
