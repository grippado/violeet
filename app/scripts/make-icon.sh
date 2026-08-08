#!/usr/bin/env bash
#
# Regenerate app/Resources/violeet.icns from the source artwork.
#
# The .icns is committed because `package.sh` copies it and a release must not
# depend on anyone's local tooling. But a committed binary with no recorded way
# to rebuild it is artwork that can only be changed by whoever made it the first
# time — so this script is the recorded way.
#
# Usage:
#   scripts/make-icon.sh [SOURCE.png]
#
# The source defaults to the artwork at the repository root. It must be square
# and at least 1024×1024; everything below is downscaled from it.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

SOURCE="${1:-../Violeet-icon.png}"
OUTPUT="Resources/violeet.icns"

[[ -f "$SOURCE" ]] || { echo "make-icon.sh: no such file: $SOURCE" >&2; exit 1; }

WIDTH="$(sips -g pixelWidth "$SOURCE" | awk '/pixelWidth/ {print $2}')"
HEIGHT="$(sips -g pixelHeight "$SOURCE" | awk '/pixelHeight/ {print $2}')"
[[ "$WIDTH" == "$HEIGHT" ]] || { echo "make-icon.sh: source is not square (${WIDTH}×${HEIGHT})" >&2; exit 1; }
(( WIDTH >= 1024 )) || { echo "make-icon.sh: source is ${WIDTH}px; 1024 is the minimum" >&2; exit 1; }

ICONSET="$(mktemp -d)/violeet.iconset"
mkdir -p "$ICONSET"
trap 'rm -rf "$(dirname "$ICONSET")"' EXIT

# The exact set `iconutil` expects. Missing sizes are not an error to it — they
# are a Dock that falls back to a blurry upscale at whatever size is missing.
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil --convert icns "$ICONSET" --output "$OUTPUT"
echo "==> $OUTPUT"
