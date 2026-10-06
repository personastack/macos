#!/bin/sh
set -eu
# Only the macOS Installer's privileged upgrade path runs this script.
[ "${3:-}" = / ] || exit 1
[ "$(/usr/bin/id -u)" = 0 ] || exit 1
helper='/Library/Application Support/PersonaStack/LockedControlInstaller'
receipt='/Library/Application Support/PersonaStack/LockedControlPolicyBaseline.plist'
plugin='/Library/Security/SecurityAgentPlugins/PersonaStackLockedGrantCandidate.bundle'
# Fresh installs and already restored installations require no policy mutation.
if [ ! -e "$plugin" ] && [ ! -L "$plugin" ] && [ ! -e "$receipt" ] && [ ! -L "$receipt" ]; then
    exit 0
fi
check_path() {
    item=$1
    [ ! -L "$item" ] || exit 1
    if [ -e "$item" ]; then
        [ "$(/usr/bin/stat -f %u "$item")" = 0 ] || exit 1
        mode=$(/usr/bin/stat -f %Lp "$item")
        [ "$((0$mode & 022))" = 0 ] || exit 1
    fi
}
for item in /Library /Library/Security /Library/Security/SecurityAgentPlugins \
    '/Library/Application Support' '/Library/Application Support/PersonaStack' \
    "$helper" "$receipt" "$plugin"; do
    check_path "$item"
done
[ -f "$helper" ] && [ -x "$helper" ] && [ -d "$plugin" ] || {
    echo 'Legacy Desktop Control needs its signed removal utility and original plug-in before upgrade.' >&2
    exit 1
}
# Packaging replaces this marker with the checked-in Developer ID certificate hash.
/usr/bin/codesign --verify --strict -R '=identifier "ai.personastack.locked-control-installer" and anchor apple generic and certificate leaf = H"__CERT_SHA1__"' "$helper"
# The signed utility validates the plug-in and saved baseline. A conflict stops
# the upgrade before payload deletion. Never edit authorizationdb from this script.
"$helper" --remove
# The utility removes its baseline only after verified policy restoration.
# Remove only the retired fixed payload after that success.
/bin/rm -rf -- "$plugin"
/bin/rm -f -- "$helper"
exit 0
