#!/usr/bin/env bash
# Regenerates SoundOwl.xcodeproj from project.yml. Commit both.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "Install XcodeGen: brew install xcodegen" >&2; exit 1; }
xcodegen generate --spec project.yml --quiet
echo "Generated SoundOwl.xcodeproj"
