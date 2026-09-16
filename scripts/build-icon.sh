#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_png="$root_dir/../art/personastack-512.png"
iconset_dir="$root_dir/build/AppIcon.iconset"
output="$root_dir/Resources/AppIcon.icns"

test -f "$source_png"
rm -rf "$iconset_dir"
mkdir -p "$iconset_dir"

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$source_png" --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
  double_size=$((size * 2))
  sips -z "$double_size" "$double_size" "$source_png" --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$iconset_dir" -o "$output"
