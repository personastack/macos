#!/bin/sh
set -eu

source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH= cd -- "$source_dir/../.." && pwd)
output_dir=${1:?usage: build.sh OUTPUT_DIRECTORY}
sdk_path=$(xcrun --sdk macosx --show-sdk-path)
bundle_dir="$output_dir/PersonaStackLockedGrantCandidate.bundle"
contents_dir="$bundle_dir/Contents"

if [ -e "$bundle_dir" ]; then
    printf '%s\n' "Refusing to replace existing candidate bundle: $bundle_dir" >&2
    exit 1
fi
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
nice -n 15 xcrun --sdk macosx clang -isysroot "$sdk_path" -arch arm64 -arch x86_64 \
    -std=c11 -Wall -Wextra -Werror -fvisibility=hidden -bundle \
    -Wl,-exported_symbol,_AuthorizationPluginCreate \
    -framework Security -framework SystemConfiguration -framework CoreFoundation \
    -lbsm -I "$repo_dir/Sources/LockedControlAudit/include" \
    "$source_dir/AuthorizationGrantPlugin.c" "$repo_dir/Sources/LockedControlAudit/LockedControlAudit.c" \
    -o "$contents_dir/MacOS/AuthorizationGrantPlugin"
cp "$repo_dir/Resources/ReleaseSigningCertificate.der" "$contents_dir/Resources/ReleaseSigningCertificate.der"
chmod 0444 "$contents_dir/Resources/ReleaseSigningCertificate.der"
cat > "$contents_dir/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>AuthorizationGrantPlugin</string>
    <key>CFBundleIdentifier</key><string>ai.personastack.locked-grant-candidate</string>
    <key>CFBundleName</key><string>PersonaStack Locked Grant Candidate</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleVersion</key><string>1</string>
</dict>
</plist>
PLIST
codesign --sign - --timestamp=none "$bundle_dir"
codesign --verify --strict "$bundle_dir"

test_binary="$output_dir/AuthorizationGrantPluginTests"
nice -n 15 xcrun --sdk macosx clang -isysroot "$sdk_path" -arch arm64 -arch x86_64 \
    -std=c11 -Wall -Wextra -Werror -DPERSONASTACK_LOCKED_GRANT_TESTING \
    -framework Security -framework SystemConfiguration -framework CoreFoundation \
    -lbsm -I "$repo_dir/Sources/LockedControlAudit/include" \
    "$source_dir/AuthorizationGrantPlugin.c" "$source_dir/AuthorizationGrantPluginTests.c" \
    "$repo_dir/Sources/LockedControlAudit/LockedControlAudit.c" -o "$test_binary"
"$test_binary"

cp "$source_dir/policy.py" "$output_dir/policy.py"
cp "$repo_dir/Experiments/LockedSessionProbe/policy.py" "$output_dir/policy_base.py"
python3 "$output_dir/policy.py" leaf "$output_dir/candidate-right.plist"
python3 -m unittest discover -s "$source_dir" -p test_policy.py
