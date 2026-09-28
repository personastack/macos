#!/bin/sh
set -eu

bundle=${1:?usage: verify-update-bundle.sh APP_BUNDLE VERSION [PUBLIC_KEY]}
version=${2:?usage: verify-update-bundle.sh APP_BUNDLE VERSION [PUBLIC_KEY]}
expected_public_key=${3:-}
plist="$bundle/Contents/Info.plist"
framework="$bundle/Contents/Frameworks/Sparkle.framework"

test -d "$bundle/Contents/MacOS"
test -x "$bundle/Contents/MacOS/PersonaStack"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" = "$version"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" = "$version"
test "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$plist")" = 'https://raw.githubusercontent.com/personastack/homebrew-tap/main/appcast.xml'
test "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$plist" 2>/dev/null || true)" = "$expected_public_key"
lipo "$bundle/Contents/MacOS/PersonaStack" -verify_arch arm64
lipo "$bundle/Contents/MacOS/PersonaStack" -verify_arch x86_64
test -x "$framework/Versions/B/Autoupdate"
test -x "$framework/Versions/B/Updater.app/Contents/MacOS/Updater"
test -x "$framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
test -x "$framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"
lipo "$framework/Versions/B/Sparkle" -verify_arch arm64
lipo "$framework/Versions/B/Sparkle" -verify_arch x86_64
codesign --verify --deep --strict "$framework"
otool -l "$bundle/Contents/MacOS/PersonaStack" | grep -A2 LC_RPATH | grep -Fq '@executable_path/../Frameworks'
otool -L "$bundle/Contents/MacOS/PersonaStack" | grep -Fq '@rpath/Sparkle.framework/Versions/B/Sparkle'
