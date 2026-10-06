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
test "$(basename "$dmg_path")" = "PersonaStack-$version-developerid.dmg"
sha256=$(shasum -a 256 "$dmg_path" | awk '{print $1}')

mkdir -p "$(dirname "$output_path")"
cat >"$output_path" <<EOF
cask "personastack" do
  version "$version"
  sha256 "$sha256"

  url "https://raw.githubusercontent.com/personastack/homebrew-tap/desktop-v#{version}/Downloads/PersonaStack-#{version}-developerid.dmg"
  name "PersonaStack"
  desc "Native macOS client for PersonaStack"
  homepage "https://my.personastack.ai"

  depends_on macos: :sonoma

  pkg "Install PersonaStack.pkg"
  auto_updates true

  uninstall quit: "ai.personastack.desktop",
            script: [{
              executable: "/Applications/PersonaStack.app/Contents/MacOS/PersonaStack",
              args: ["--personastack-unregister-login"],
              sudo: false,
              must_succeed: true,
            }, {
              executable: "/bin/sh",
              args: ["-c", 'if [ -e "/Library/Application Support/PersonaStack/LockedControlInstaller" ]; then exec "/Library/Application Support/PersonaStack/LockedControlInstaller" --remove; elif [ -e "/Library/Security/SecurityAgentPlugins/PersonaStackLockedGrantCandidate.bundle" ]; then echo "Legacy locked-control cleanup requires its signed removal utility." >&2; exit 1; fi'],
              sudo: true,
              must_succeed: true,
            }],
            pkgutil: ["ai.personastack.desktop", "ai.personastack.locked-control"]

end
EOF
