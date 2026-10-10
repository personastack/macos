#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
bundle=${1:?usage: sign-app.sh APP_BUNDLE}
: "${PERSONASTACK_CODESIGN_IDENTITY:?Developer ID Application identity is required}"
: "${PERSONASTACK_CODESIGN_KEYCHAIN:?signing keychain is required}"

# Validate dependency lookup before signing any nested code.
sh "$root_dir/scripts/verify-sparkle-runtime.sh" "$bundle"

sign() {
  codesign --force --timestamp --options runtime \
    --keychain "$PERSONASTACK_CODESIGN_KEYCHAIN" \
    --sign "$PERSONASTACK_CODESIGN_IDENTITY" "$@"
}

# Sign nested code before its containing bundle, following Sparkle's manual
# distribution procedure. Preserve Downloader's own entitlements only.
framework="$bundle/Contents/Frameworks/Sparkle.framework"
if [ -d "$framework" ]; then
  sign "$framework/Versions/B/XPCServices/Installer.xpc"
  sign --preserve-metadata=entitlements "$framework/Versions/B/XPCServices/Downloader.xpc"
  sign "$framework/Versions/B/Autoupdate"
  sign "$framework/Versions/B/Updater.app"
  sign "$framework"
fi
sign --identifier ai.personastack.desktop.harness-hook "$bundle/Contents/MacOS/PersonaStackHarnessHook"
sign --identifier ai.personastack.desktop.agent-bridge "$bundle/Contents/MacOS/PersonaStackAgentBridge"
sign --identifier ai.personastack.desktop \
  --entitlements "$root_dir/Resources/Release.entitlements" "$bundle"
"$root_dir/scripts/verify-app-signature.sh" "$bundle"
