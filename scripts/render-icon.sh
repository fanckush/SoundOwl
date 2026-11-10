#!/usr/bin/env bash
# Renders the app icon (from SoundOwl/Views/OwlMark.swift) into the asset catalog and the site.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD=build/icon
mkdir -p "$BUILD"
swiftc -O -o "$BUILD/render" scripts/icon/main.swift SoundOwl/Views/OwlMark.swift
"$BUILD/render" "$BUILD"

SET=SoundOwl/Assets.xcassets/AppIcon.appiconset
images=""
for size in 16 32 128 256 512; do
  for scale in 1 2; do
    px=$((size * scale))
    suffix=""
    if [[ $scale == 2 ]]; then suffix="@2x"; fi
    name="icon_${size}x${size}${suffix}.png"
    sips -z $px $px "$BUILD/icon-1024.png" --out "$SET/$name" >/dev/null
    images+="    { \"idiom\" : \"mac\", \"scale\" : \"${scale}x\", \"size\" : \"${size}x${size}\", \"filename\" : \"$name\" },"$'\n'
  done
done
printf '{\n  "images" : [\n%s  ],\n  "info" : { "author" : "xcode", "version" : 1 }\n}\n' "${images%,$'\n'}"$'\n' > "$SET/Contents.json"

mkdir -p site/assets
cp "$BUILD/icon-1024.png" site/assets/icon-1024.png
sips -z 512 512 "$BUILD/icon-1024.png" --out site/assets/icon-512.png >/dev/null
sips -z 180 180 "$BUILD/icon-1024.png" --out site/apple-touch-icon.png >/dev/null
sips -z 64 64 "$BUILD/icon-1024.png" --out site/assets/icon-64.png >/dev/null
sips -z 32 32 "$BUILD/icon-1024.png" --out site/favicon.png >/dev/null
echo "Icon written to $SET and site/"
