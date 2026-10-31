#!/bin/zsh
set -euo pipefail

iconset_path=".build/MyWizard.iconset"
mkdir -p "$iconset_path"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" App/MyWizard-logo.png --out "$iconset_path/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    sips -z "$retina_size" "$retina_size" App/MyWizard-logo.png --out "$iconset_path/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns "$iconset_path" --output App/MyWizard.icns
