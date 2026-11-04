#!/bin/sh
set -eu
root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
destination=${1:?usage: build-agent-bridge.sh OUTPUT_DIRECTORY VERSION}
version=${2:?usage: build-agent-bridge.sh OUTPUT_DIRECTORY VERSION}
case "$version" in
  *[!0-9.]*|'') printf '%s\n' 'Agent bridge version must be numeric.' >&2; exit 2 ;;
esac
mkdir -p "$destination"
destination=$(CDPATH= cd -- "$destination" && pwd)
source_module="$root_dir/agent-bridge"
test -f "$source_module/go.mod"
sdk_path=$(xcrun --sdk macosx --show-sdk-path)
(
  cd "$source_module"
  GOFLAGS=-mod=vendor GOPROXY=off GOSUMDB=off \
    GOOS=darwin GOARCH=arm64 CGO_ENABLED=1 \
    CC="clang -arch arm64" \
    CGO_CFLAGS="-isysroot $sdk_path -mmacosx-version-min=14.0" \
    CGO_LDFLAGS="-isysroot $sdk_path -mmacosx-version-min=14.0" \
    go build -trimpath \
      -ldflags "-X github.com/personastack/macos/agent-bridge/internal/buildinfo.Version=$version" \
      -o "$destination/PersonaStackAgentBridge" ./cmd/personastack-agent-bridge
)
sh "$root_dir/scripts/verify-arm64-binaries.sh" "$destination/PersonaStackAgentBridge"
chmod 755 "$destination/PersonaStackAgentBridge"
