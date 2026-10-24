#!/bin/bash
set -euo pipefail
ROOT=$(cd -P "$(dirname "$0")/.." && pwd)
command -v rsvg-convert >/dev/null || { echo "Icon regeneration needs rsvg-convert (librsvg)." >&2; exit 1; }
[[ ! -L "$ROOT/.release-tmp" ]] || { echo "Temporary directory must not be a symlink." >&2; exit 1; }
mkdir -p "$ROOT/.release-tmp"
WORK=$(mktemp -d "$ROOT/.release-tmp/icon.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/Pastty.iconset"
rsvg-convert -w 1024 -h 1024 "$ROOT/assets/Pastty.svg" -o "$WORK/master.png"
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" "$WORK/master.png" --out "$WORK/Pastty.iconset/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    sips -z "$DOUBLE" "$DOUBLE" "$WORK/master.png" --out "$WORK/Pastty.iconset/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$WORK/Pastty.iconset" -o "$WORK/Pastty.icns"
cp "$WORK/master.png" "$ROOT/assets/Pastty-1024.png"
cp "$WORK/Pastty.icns" "$ROOT/packaging/Pastty.icns"
rsvg-convert -w 36 -h 36 "$ROOT/assets/MenuIconTemplate.svg" -o "$ROOT/packaging/MenuIconTemplate.png"
echo "Regenerated Pastty PNG, ICNS and monochrome menu icon from SVG."
