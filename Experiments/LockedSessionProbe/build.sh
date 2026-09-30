#!/bin/bash
# Build a diagnostic kit only. Never installs a plug-in or changes OS policy.
set -euo pipefail

if [[ $# -ne 1 || -z "$1" ]]; then
    echo "Usage: bash build.sh NEW_OUTPUT_DIRECTORY" >&2
    exit 2
fi
source_dir=$(cd -- "$(dirname -- "$0")" && pwd)
output_dir=$1
# mkdir refuses an existing directory or symlink. No existing artifacts are overwritten.
mkdir -m 700 -- "$output_dir"
output_dir=$(cd -- "$output_dir" && pwd)

build_id=$(PYTHONDONTWRITEBYTECODE=1 nice -n 15 python3 "$source_dir/receipt.py" identity "$source_dir")
build_version=$(PYTHONDONTWRITEBYTECODE=1 nice -n 15 python3 "$source_dir/receipt.py" version)
flags=(-std=c11 -Wall -Wextra -Werror -mmacosx-version-min=14.0 "-DPROBE_BUILD_ID=\"$build_id\"")
sanitizers=(-fsanitize=address,undefined -fno-omit-frame-pointer -g)
frameworks=(-framework Security -framework CoreFoundation)

# All builds are serial and low priority. No Swift package or upstream runtime rebuild.
nice -n 15 clang "${flags[@]}" "${sanitizers[@]}" -DPROBE_LOG_TEST \
    "$source_dir/AuthorizationProbe.c" "$source_dir/AuthorizationProbeTests.c" \
    "${frameworks[@]}" -o "$output_dir/authorization-tests"
nice -n 15 "$output_dir/authorization-tests"
nice -n 15 clang "${flags[@]}" "${sanitizers[@]}" -DPROBE_TEST \
    "$source_dir/ProbeActions.c" "$source_dir/ProbeActionsTests.c" \
    "${frameworks[@]}" -framework IOKit -o "$output_dir/action-tests"
nice -n 15 "$output_dir/action-tests"
(
    cd -- "$source_dir"
    PYTHONDONTWRITEBYTECODE=1 nice -n 15 python3 -m unittest -v test_policy test_receipt
)

bundle="$output_dir/PersonaStackLockedSessionProbe.bundle"
mkdir -p -- "$bundle/Contents/MacOS"
for architecture in arm64 x86_64; do
    nice -n 15 clang "${flags[@]}" -arch "$architecture" -O2 -fvisibility=hidden -bundle \
        "$source_dir/AuthorizationProbe.c" "${frameworks[@]}" \
        -o "$output_dir/authorization-$architecture"
    nice -n 15 clang "${flags[@]}" -arch "$architecture" -O2 \
        "$source_dir/ProbeActions.c" "${frameworks[@]}" -framework IOKit \
        -o "$output_dir/probe-$architecture"
done
nice -n 15 lipo -create "$output_dir/authorization-arm64" "$output_dir/authorization-x86_64" \
    -output "$bundle/Contents/MacOS/PersonaStackLockedSessionProbe"
nice -n 15 lipo -create "$output_dir/probe-arm64" "$output_dir/probe-x86_64" \
    -output "$output_dir/personastack-locked-session-probe"
cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>ai.personastack.locked-session-probe</string>
<key>CFBundleName</key><string>PersonaStack Locked Session Probe</string>
<key>CFBundleExecutable</key><string>PersonaStackLockedSessionProbe</string>
<key>CFBundlePackageType</key><string>BNDL</string>
<key>CFBundleVersion</key><string>$build_version</string>
<key>CFBundleShortVersionString</key><string>0.0.$build_version</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
# Development-only ad-hoc identity. This is not Developer ID or notarization.
nice -n 15 codesign --sign - --timestamp=none "$bundle"
nice -n 15 codesign --sign - --timestamp=none "$output_dir/personastack-locked-session-probe"
nice -n 15 codesign --verify --strict "$bundle"
nice -n 15 codesign --verify --strict "$output_dir/personastack-locked-session-probe"
for architecture in arm64 x86_64; do
    nice -n 15 lipo -verify_arch "$architecture" "$bundle/Contents/MacOS/PersonaStackLockedSessionProbe"
    nice -n 15 lipo -verify_arch "$architecture" "$output_dir/personastack-locked-session-probe"
done
cp -- "$source_dir/policy.py" "$source_dir/receipt.py" "$source_dir/README.md" "$output_dir/"
PYTHONDONTWRITEBYTECODE=1 nice -n 15 python3 "$source_dir/policy.py" leaf "$output_dir/probe-right.plist"
PYTHONDONTWRITEBYTECODE=1 nice -n 15 python3 "$source_dir/receipt.py" manifest "$source_dir" "$output_dir" "$build_id"
# Help has no OS effects. Do not execute the actual diagnostic actions on this Mac.
nice -n 15 "$output_dir/personastack-locked-session-probe" --help
echo "Diagnostic kit built at $output_dir. Nothing was installed."
