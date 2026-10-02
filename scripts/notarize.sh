#!/bin/sh
set -eu

target=${1:?usage: notarize.sh APP_OR_DMG}
: "${PERSONASTACK_NOTARY_KEY_PATH:?notarization API private key is required}"
: "${PERSONASTACK_NOTARY_KEY_ID:?notarization API key ID is required}"
: "${PERSONASTACK_NOTARY_ISSUER_ID:?notarization API issuer ID is required}"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/personastack-notarize.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

case "$target" in
  *.app)
    archive="$work_dir/PersonaStack.zip"
    ditto -c -k --keepParent "$target" "$archive"
    ;;
  *.dmg) archive="$target" ;;
  *) printf '%s\n' 'Only an app bundle or DMG can be notarized.' >&2; exit 2 ;;
esac

notary() {
  xcrun notarytool "$@" --key "$PERSONASTACK_NOTARY_KEY_PATH" \
    --key-id "$PERSONASTACK_NOTARY_KEY_ID" --issuer "$PERSONASTACK_NOTARY_ISSUER_ID"
}

notary submit "$archive" --wait --timeout 60m --output-format json > "$work_dir/result.json"
cat "$work_dir/result.json"
if ! python3 - "$work_dir/result.json" <<'PYTHON'
import json
import sys
result = json.load(open(sys.argv[1]))
sys.exit(0 if result.get("status") == "Accepted" else 1)
PYTHON
then
  submission_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$work_dir/result.json")
  notary log "$submission_id" "$work_dir/notary-log.json"
  cat "$work_dir/notary-log.json"
  exit 1
fi
xcrun stapler staple "$target"
xcrun stapler validate "$target"
