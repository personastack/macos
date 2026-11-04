#!/bin/sh
set -eu

test "$#" -gt 0
for binary in "$@"; do
  architectures=$(lipo -archs "$binary")
  if [ "$architectures" != arm64 ]; then
    printf '%s\n' "Expected ARM64-only executable: $binary (found: $architectures)" >&2
    exit 1
  fi
done
