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
for architecture in arm64 amd64; do
  native_architecture=$architecture
  if [ "$architecture" = amd64 ]; then native_architecture=x86_64; fi
  (
    cd "$source_module"
    GOFLAGS=-mod=vendor GOPROXY=off GOSUMDB=off \
      GOOS=darwin GOARCH="$architecture" CGO_ENABLED=1 \
      CC="clang -arch $native_architecture" \
      CGO_CFLAGS="-isysroot $sdk_path -mmacosx-version-min=14.0" \
      CGO_LDFLAGS="-isysroot $sdk_path -mmacosx-version-min=14.0" \
      go build -trimpath \
        -ldflags "-X github.com/personastack/macos/agent-bridge/internal/buildinfo.Version=$version" \
        -o "$destination/PersonaStackAgentBridge-$architecture" ./cmd/personastack-agent-bridge
  )
done
lipo -create "$destination/PersonaStackAgentBridge-arm64" "$destination/PersonaStackAgentBridge-amd64" \
  -output "$destination/PersonaStackAgentBridge"
lipo -verify_arch arm64 "$destination/PersonaStackAgentBridge"
lipo -verify_arch x86_64 "$destination/PersonaStackAgentBridge"
chmod 755 "$destination/PersonaStackAgentBridge"
