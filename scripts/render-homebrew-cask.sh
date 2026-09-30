#!/bin/sh
set -eu

version=${1:?usage: render-homebrew-cask.sh VERSION DMG_PATH OUTPUT_PATH}
dmg_path=${2:?usage: render-homebrew-cask.sh VERSION DMG_PATH OUTPUT_PATH}
output_path=${3:?usage: render-homebrew-cask.sh VERSION DMG_PATH OUTPUT_PATH}
if ! printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  printf '%s\n' "Stable cask version must use numeric major.minor.patch: $version" >&2
  exit 2
fi
test -f "$dmg_path"
test "$(basename "$dmg_path")" = "PersonaStack-$version-selfsigned.dmg"
sha256=$(shasum -a 256 "$dmg_path" | awk '{print $1}')

mkdir -p "$(dirname "$output_path")"
cat >"$output_path" <<EOF
cask "personastack" do
  version "$version"
  sha256 "$sha256"

  url "https://raw.githubusercontent.com/personastack/homebrew-tap/desktop-v#{version}/Downloads/PersonaStack-#{version}-selfsigned.dmg"
  name "PersonaStack"
  desc "Native macOS client for PersonaStack"
  homepage "https://my.personastack.ai"

  depends_on macos: :sonoma

  app "PersonaStack.app"
  auto_updates true

  caveats <<~EOS
    PersonaStack uses a persistent self-signed certificate. It is not Developer ID signed or notarized.
    macOS may require a Gatekeeper override the first time you open it.
  EOS
end
EOF
