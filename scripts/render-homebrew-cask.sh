#!/bin/sh
set -eu

version=${1:?usage: render-homebrew-cask.sh VERSION DMG_PATH OUTPUT_PATH}
dmg_path=${2:?usage: render-homebrew-cask.sh VERSION DMG_PATH OUTPUT_PATH}
output_path=${3:?usage: render-homebrew-cask.sh VERSION DMG_PATH OUTPUT_PATH}
sha256=$(shasum -a 256 "$dmg_path" | awk '{print $1}')

mkdir -p "$(dirname "$output_path")"
cat >"$output_path" <<EOF
cask "personastack" do
  version "$version"
  sha256 "$sha256"

  url "https://raw.githubusercontent.com/personastack/homebrew-tap/desktop-v#{version}/Downloads/PersonaStack-#{version}-unsigned.dmg"
  name "PersonaStack"
  desc "Native macOS client for PersonaStack"
  homepage "https://my.personastack.ai"

  depends_on macos: :sonoma

  app "PersonaStack.app"

  caveats <<~EOS
    PersonaStack is unsigned. macOS may require a Gatekeeper override the first time you open it.
  EOS
end
EOF
