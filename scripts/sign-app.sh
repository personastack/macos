#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
bundle=${1:?usage: sign-app.sh APP_BUNDLE}
: "${PERSONASTACK_CODESIGN_IDENTITY:?Developer ID Application identity is required}"
: "${PERSONASTACK_CODESIGN_KEYCHAIN:?signing keychain is required}"

# This restricted entitlement must be authorized before signing any code.
python3 "$root_dir/scripts/communication_profile.py" embed "$bundle"

# Validate dependency lookup before signing any nested code.
sh "$root_dir/scripts/verify-sparkle-runtime.sh" "$bundle"
python3 "$root_dir/scripts/lima_runtime.py" verify-unsigned "$bundle"

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
sign --identifier ai.personastack.desktop.lima \
  --entitlements "$root_dir/Resources/Lima.entitlements" \
  "$bundle/Contents/Resources/LocalCluster/lima/bin/limactl"
python3 "$root_dir/scripts/lima_runtime.py" seal "$bundle"
if [ -f "$bundle/Contents/Resources/imsg-provider-manifest.json" ]; then
  sign --identifier ai.personastack.desktop.imsg \
    --entitlements "$root_dir/Resources/IMessageProvider.entitlements" "$bundle/Contents/MacOS/imsg"
  python3 "$root_dir/third_party/imsg/bundle.py" --app-bundle "$bundle" --seal-existing
fi
sign --identifier ai.personastack.desktop \
  --entitlements "$root_dir/Resources/Release.entitlements" "$bundle"
"$root_dir/scripts/verify-app-signature.sh" "$bundle"
