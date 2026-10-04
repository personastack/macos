#!/bin/sh
set -eu

bundle=${1:?usage: verify-update-bundle.sh APP_BUNDLE VERSION [PUBLIC_KEY]}
version=${2:?usage: verify-update-bundle.sh APP_BUNDLE VERSION [PUBLIC_KEY]}
expected_public_key=${3:-}
plist="$bundle/Contents/Info.plist"
framework="$bundle/Contents/Frameworks/Sparkle.framework"
root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

"$root_dir/scripts/verify-app-signature.sh" "$bundle"

test -d "$bundle/Contents/MacOS"
test -x "$bundle/Contents/MacOS/PersonaStack"
test -x "$bundle/Contents/MacOS/PersonaStackHarnessHook"
test -s "$bundle/Contents/Resources/AppIcon.icns"
test -s "$bundle/Contents/Resources/MenuBarIcon.png"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" = "$version"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" = "$version"
test "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$plist")" = 'https://raw.githubusercontent.com/personastack/homebrew-tap/main/appcast.xml'
test "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$plist" 2>/dev/null || true)" = "$expected_public_key"
lipo "$bundle/Contents/MacOS/PersonaStack" -verify_arch arm64
lipo "$bundle/Contents/MacOS/PersonaStack" -verify_arch x86_64
lipo "$bundle/Contents/MacOS/PersonaStackHarnessHook" -verify_arch arm64
lipo "$bundle/Contents/MacOS/PersonaStackHarnessHook" -verify_arch x86_64
test -x "$framework/Versions/B/Autoupdate"
test -x "$framework/Versions/B/Updater.app/Contents/MacOS/Updater"
test -x "$framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
test -x "$framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"
lipo "$framework/Versions/B/Sparkle" -verify_arch arm64
lipo "$framework/Versions/B/Sparkle" -verify_arch x86_64
codesign --verify --deep --strict "$framework"
verification_dir=$(mktemp -d "${TMPDIR:-/tmp}/personastack-nested-signatures.XXXXXX")
trap 'rm -rf "$verification_dir"' EXIT
for code in "$framework/Versions/B/XPCServices/Installer.xpc" \
  "$framework/Versions/B/XPCServices/Downloader.xpc" \
  "$framework/Versions/B/Autoupdate" "$framework/Versions/B/Updater.app" "$framework"; do
  codesign --verify --strict "$code"
  codesign --display --verbose=4 "$code" > "$verification_dir/details" 2>&1
  codesign --display --extract-certificates="$verification_dir/certificate" "$code" >/dev/null 2>&1
  cmp "$root_dir/Resources/ReleaseSigningCertificate.der" "$verification_dir/certificate0"
  grep -Fxq 'TeamIdentifier=5T2T8KL852' "$verification_dir/details"
  grep -Fq '(runtime)' "$verification_dir/details"
  grep -q '^Timestamp=' "$verification_dir/details"
done
sh "$root_dir/scripts/verify-sparkle-runtime.sh" "$bundle"
otool -L "$bundle/Contents/MacOS/PersonaStack" | grep -Fq '@rpath/Sparkle.framework/Versions/B/Sparkle'
