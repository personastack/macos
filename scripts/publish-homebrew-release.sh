#!/bin/bash
# Publish the finalized CI installer to the public tap. Never rebuild it here.
set -euo pipefail

version=${1:?usage: publish-homebrew-release.sh VERSION DMG TAP_DIR SPARKLE_DIR NOTES}
dmg=${2:?missing finalized DMG}
tap_dir=${3:?missing tap checkout}
sparkle_dir=${4:?missing pinned Sparkle tools}
notes=${5:?missing authored release notes}
: "${GH_TOKEN:?Homebrew tap write token is required}"
: "${SPARKLE_PRIVATE_KEY:?Sparkle signing key is required}"
: "${RUNNER_TEMP:?Runner temporary directory is required}"
scripts_dir=$(cd "$(dirname "$0")" && pwd)
# Resolve paths before entering the tap checkout.
dmg=$(cd "$(dirname "$dmg")" && printf '%s/%s' "$PWD" "$(basename "$dmg")")
notes=$(cd "$(dirname "$notes")" && printf '%s/%s' "$PWD" "$(basename "$notes")")
sparkle_dir=$(cd "$sparkle_dir" && pwd)
python3 "$scripts_dir/release_notes.py" "$version" "$notes"
test -f "$dmg"
test "$(basename "$dmg")" = "PersonaStack-$version-developerid.dmg"
test -x "$sparkle_dir/bin/sign_update"
tap_tag="desktop-v$version"
cd "$tap_dir"
python3 - "$version" <<'PY'
from pathlib import Path
import re
import sys

cask = Path("Casks/personastack.rb")
if cask.exists():
    match = re.search(r'^\s*version "([0-9]+\.[0-9]+\.[0-9]+)"\s*$', cask.read_text(), re.MULTILINE)
    if match is None:
        raise SystemExit("Current Homebrew cask must have a numeric release version")
    current = match.group(1)
    numeric = lambda version: tuple(map(int, version.split(".")))
    if numeric(sys.argv[1]) <= numeric(current):
        raise SystemExit(f"Homebrew release {sys.argv[1]} must be newer than current cask {current}")
PY
if git rev-parse -q --verify "refs/tags/$tap_tag" >/dev/null; then
  echo "Homebrew installer tag $tap_tag already exists." >&2
  exit 1
fi
if gh release view --repo personastack/homebrew-tap "$tap_tag" >/dev/null 2>&1; then
  echo "Homebrew release $tap_tag already exists." >&2
  exit 1
fi

mkdir -p Casks Downloads
current_dmg="Downloads/$(basename "$dmg")"
cp "$dmg" "$current_dmg"
"$scripts_dir/render-homebrew-cask.sh" "$version" "$current_dmg" Casks/personastack.rb
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add Casks/personastack.rb "$current_dmg"
git commit -m "feat: publish PersonaStack cask $version"
git tag -a "$tap_tag" -m "PersonaStack $version"
git push origin HEAD:main "refs/tags/$tap_tag"

latest_dmg="$RUNNER_TEMP/PersonaStack-latest.dmg"
cp "$current_dmg" "$latest_dmg"
gh release create --repo personastack/homebrew-tap \
  "$tap_tag" "$current_dmg" "$latest_dmg" \
  --title "PersonaStack $version" --notes-file "$notes" --latest

archive_dir=$(mktemp -d "$RUNNER_TEMP/personastack-appcast.XXXXXX")
if [ -f appcast.xml ]; then cp appcast.xml "$archive_dir/appcast.xml"; fi
archive_signature=$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$sparkle_dir/bin/sign_update" \
  --ed-key-file - -p "$dmg")
python3 "$scripts_dir/render-package-appcast.py" \
  "$version" "$dmg" "$notes" "$archive_signature" "$archive_dir/appcast.xml"
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$sparkle_dir/bin/sign_update" \
  --ed-key-file - "$archive_dir/appcast.xml"
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$sparkle_dir/bin/sign_update" \
  --ed-key-file - --verify "$dmg" "$archive_signature"
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$sparkle_dir/bin/sign_update" \
  --ed-key-file - --verify "$archive_dir/appcast.xml"
python3 "$scripts_dir/validate-appcast.py" \
  "$archive_dir/appcast.xml" "$version" "$tap_tag" "$dmg" Casks/personastack.rb "$notes"
cp "$archive_dir/appcast.xml" appcast.xml
git add appcast.xml
git commit -m "feat: publish signed PersonaStack appcast $version"
git push origin HEAD:main
