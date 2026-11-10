#!/usr/bin/env bash
#
# Download the published model package into tools/model-export/build/, where the tests and
# soundowl-dev look for it. The URL and checksum are read from ModelRelease.swift, the one place
# the app pins them. Rebuilding the package from upstream instead: see tools/model-export.
#
# Usage: scripts/fetch-model.sh [--optional]
#   --optional  Exit 0 with a warning if the package can't be downloaded (CI before the first
#               model release exists). The model-dependent tests then skip themselves.
set -euo pipefail

cd "$(dirname "$0")/.."

OPTIONAL=0
[[ "${1:-}" == "--optional" ]] && OPTIONAL=1

RELEASE="Sources/SoundOwlCore/Models/ModelRelease.swift"
URL=$(sed -nE 's/.*url: URL\(string: "([^"]+\.zip)"\).*/\1/p' "$RELEASE" | head -1)
SHA=$(sed -nE 's/.*sha256: "([0-9a-f]{64})".*/\1/p' "$RELEASE" | head -1)
[[ -n "$URL" && -n "$SHA" ]] || { echo "!! couldn't read the model URL and checksum from $RELEASE" >&2; exit 1; }

BUILD="tools/model-export/build"
ZIP="$BUILD/$(basename "$URL")"
DIR="$BUILD/$(basename "$URL" .zip | sed -E 's/-[0-9]+$//')"

if [[ -f "$ZIP" ]] && echo "$SHA  $ZIP" | shasum -a 256 -c --status && [[ -f "$DIR/model.json" ]]; then
  echo ">> Model package already in $DIR"
  exit 0
fi

mkdir -p "$BUILD"
echo ">> Downloading $URL"
if ! curl -fL --retry 3 -o "$ZIP.part" "$URL"; then
  rm -f "$ZIP.part"
  if [[ "$OPTIONAL" == "1" ]]; then
    echo "!! model package not available; model tests will be skipped" >&2
    exit 0
  fi
  exit 1
fi
echo "$SHA  $ZIP.part" | shasum -a 256 -c --status || { rm -f "$ZIP.part"; echo "!! checksum mismatch" >&2; exit 1; }
mv "$ZIP.part" "$ZIP"

rm -rf "$DIR"
ditto -x -k "$ZIP" "$BUILD"
[[ -f "$DIR/model.json" ]] || { echo "!! $ZIP did not contain $(basename "$DIR")/model.json" >&2; exit 1; }
echo ">> Model package in $DIR"
