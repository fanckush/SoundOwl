#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

# The engine and session tests need the model package; without it they skip themselves.
scripts/fetch-model.sh --optional

echo ">> Running Swift package tests"
swift test

echo ">> Building the app (ad-hoc signed)"
xcodebuild \
  -project SoundOwl.xcodeproj \
  -scheme SoundOwl \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath DerivedData \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  build

echo ">> Running version script tests"
python3 -m unittest discover -s scripts/tests
