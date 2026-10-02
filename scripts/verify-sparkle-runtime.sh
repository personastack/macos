#!/bin/sh
set -eu

bundle=${1:?usage: verify-sparkle-runtime.sh APP_BUNDLE}
binary="$bundle/Contents/MacOS/PersonaStack"
dependencies=$(otool -L "$binary")

# Signing-continuity fixtures do not link Sparkle. Actual app builds do.
if ! printf '%s\n' "$dependencies" | grep -Fq '@rpath/Sparkle.framework/Versions/B/Sparkle'; then
  exit 0
fi
if [ ! -x "$bundle/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" ]; then
  printf '%s\n' 'The app links Sparkle but its bundled framework is missing.' >&2
  exit 1
fi
load_commands=$(otool -l "$binary")
if ! printf '%s\n' "$load_commands" | awk '$1 == "path" && $2 == "@executable_path/../Frameworks" { found=1 } END { exit !found }'; then
  printf '%s\n' 'The app links Sparkle but is missing the @executable_path/../Frameworks runpath.' >&2
  exit 1
fi
